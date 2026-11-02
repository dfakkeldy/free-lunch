// SPDX-License-Identifier: GPL-3.0-or-later
// Draft-plate capture model and deterministic pipeline for spec §2.
import Foundation
import FLCore

public struct AIEstimationRecordData: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let photoID: UUID?
    public let kind: PhotoKind
    public let hint: String?
    public var providerTier: Int
    public var modelID: String
    public var status: AIEstimationStatus
    public var responseJSON: Data?
    public var userCorrections: [String]
    public var failure: AICaptureFailure?

    public init(
        id: UUID,
        createdAt: Date,
        photoID: UUID?,
        kind: PhotoKind,
        hint: String?,
        providerTier: Int,
        modelID: String,
        status: AIEstimationStatus,
        responseJSON: Data?,
        userCorrections: [String],
        failure: AICaptureFailure?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.photoID = photoID
        self.kind = kind
        self.hint = hint
        self.providerTier = providerTier
        self.modelID = modelID
        self.status = status
        self.responseJSON = responseJSON
        self.userCorrections = userCorrections
        self.failure = failure
    }
}

public struct CapturePlateItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public internal(set) var name: String
    public internal(set) var quantityGrams: Double
    public internal(set) var nutrition: NutritionValues
    public let provenance: ItemProvenance
    public let aiRecordID: UUID?
    public let confidence: Double?
    public internal(set) var userEdited: Bool

    public init(
        id: UUID,
        name: String,
        quantityGrams: Double,
        nutrition: NutritionValues,
        provenance: ItemProvenance,
        aiRecordID: UUID?,
        confidence: Double?,
        userEdited: Bool
    ) {
        self.id = id
        self.name = name
        self.quantityGrams = quantityGrams
        self.nutrition = nutrition
        self.provenance = provenance
        self.aiRecordID = aiRecordID
        self.confidence = confidence
        self.userEdited = userEdited
    }
}

public struct CapturePlate: Sendable, Hashable {
    public internal(set) var state: MealState
    public var items: [CapturePlateItem]
    public var records: [AIEstimationRecordData]
    var removedAIItemNames: [UUID: Set<String>] = [:]

    public init(state: MealState = .draft, items: [CapturePlateItem] = [], records: [AIEstimationRecordData] = []) {
        self.state = state
        self.items = items
        self.records = records
    }

    /// Parks a photo capture without changing a draft plate (spec §2).
    public mutating func parkCapture(
        recordID: UUID,
        createdAt: Date,
        kind: PhotoKind,
        photoID: UUID?,
        hint: String?,
        providerTier: Int,
        modelID: String
    ) {
        records.append(AIEstimationRecordData(
            id: recordID,
            createdAt: createdAt,
            photoID: photoID,
            kind: kind,
            hint: hint,
            providerTier: providerTier,
            modelID: modelID,
            status: .pending,
            responseJSON: nil,
            userCorrections: [],
            failure: nil
        ))
    }

    /// Applies a fully parsed meal result atomically; failures leave items untouched.
    /// When fewer item IDs are supplied than response items, new UUIDs are generated for the remainder.
    public mutating func applyResponse(_ data: Data, toRecord recordID: UUID, newItemIDs: [UUID]) {
        guard let recordIndex = records.firstIndex(where: { $0.id == recordID }),
              records[recordIndex].kind == .meal
        else { return }

        switch AICaptureParser.parse(data) {
        case .failure(let failure):
            failRecord(at: recordIndex, with: failure)
        case .success(let response):
            let resolvedItemIDs = response.items.indices.map { index in
                index < newItemIDs.count ? newItemIDs[index] : UUID()
            }
            applyMealResponse(response, rawData: data, recordID: recordID, recordIndex: recordIndex, newItemIDs: resolvedItemIDs)
        }
    }

    /// Queues a non-empty correction while retaining the previous estimate until replacement.
    public mutating func addCorrection(_ hint: String, toRecord recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        records[index].userCorrections.append(trimmed)
        records[index].status = .pending
        records[index].failure = nil
    }

    /// Edits a quantity while preserving its permanent provenance (spec §2).
    public mutating func setQuantity(itemID: UUID, grams: Double) {
        guard grams.isFinite, grams > 0,
              let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].quantityGrams.isFinite, items[index].quantityGrams > 0
        else { return }

        let factor = grams / items[index].quantityGrams
        guard factor.isFinite else { return }
        let old = items[index].nutrition
        let kcal = old.kcal * factor
        let protein = old.proteinG * factor
        let carbs = old.carbsG * factor
        let fat = old.fatG * factor
        let fiber = old.fiberG.map { $0 * factor }
        guard kcal.isFinite, protein.isFinite, carbs.isFinite, fat.isFinite,
              fiber?.isFinite ?? true
        else { return }
        items[index].quantityGrams = grams
        items[index].nutrition = NutritionValues(
            kcal: Kilocalories(kcal),
            protein: Grams(protein),
            carbs: Grams(carbs),
            fat: Grams(fat),
            fiber: fiber.map { Grams($0) }
        )
        items[index].userEdited = true
    }

    /// Renames an item while preserving its permanent provenance (spec §2).
    public mutating func rename(itemID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { $0.id == itemID })
        else { return }
        items[index].name = trimmed
        items[index].userEdited = true
    }

    /// Replaces nutrition values while preserving its permanent provenance (spec §2).
    public mutating func setNutrition(itemID: UUID, _ nutrition: NutritionValues) {
        guard nutrition.kcal.isFinite, nutrition.kcal >= 0,
              nutrition.proteinG.isFinite, nutrition.proteinG >= 0,
              nutrition.carbsG.isFinite, nutrition.carbsG >= 0,
              nutrition.fatG.isFinite, nutrition.fatG >= 0,
              nutrition.fiberG?.isFinite ?? true,
              nutrition.fiberG.map({ $0 >= 0 }) ?? true,
              let index = items.firstIndex(where: { $0.id == itemID })
        else { return }
        items[index].nutrition = nutrition
        items[index].userEdited = true
    }

    public mutating func addManualItem(_ item: CapturePlateItem) {
        items.append(item)
    }

    public mutating func removeItem(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let recordID = item.aiRecordID {
            removedAIItemNames[recordID, default: []].insert(normalizedCaptureName(item.name))
        }
        items.removeAll { $0.id == id }
    }

    /// Logging is the only transition out of draft (spec §2).
    public mutating func log() {
        state = .logged
    }

    public var pendingRecordIDs: [UUID] {
        records.compactMap { $0.status == .pending ? $0.id : nil }
    }

    mutating func failRecord(at index: Int, with failure: AICaptureFailure) {
        records[index].status = .failed
        records[index].failure = failure
    }

    private mutating func applyMealResponse(
        _ response: AICaptureResponse,
        rawData: Data,
        recordID: UUID,
        recordIndex: Int,
        newItemIDs: [UUID]
    ) {
        let existingIndices = items.indices.filter { items[$0].aiRecordID == recordID }
        let removedNames = removedAIItemNames[recordID, default: []]
        if existingIndices.isEmpty {
            for (index, item) in response.items.enumerated() where !removedNames.contains(normalizedCaptureName(item.name)) {
                items.append(captureItem(from: item, id: newItemIDs[index], recordID: recordID))
            }
        } else {
            replaceRerunItems(response.items, recordID: recordID, newItemIDs: newItemIDs, existingIndices: existingIndices)
        }
        records[recordIndex].status = .complete
        records[recordIndex].responseJSON = rawData
        records[recordIndex].failure = nil
    }

    /// Matches names case-insensitively after trimming whitespace. If an edited item is renamed,
    /// a re-run using a different name can add that new name alongside the edited item.
    private mutating func replaceRerunItems(
        _ responseItems: [AICaptureItem],
        recordID: UUID,
        newItemIDs: [UUID],
        existingIndices: [Int]
    ) {
        let protectedNames = Set(existingIndices.compactMap { index in
            items[index].userEdited ? normalizedCaptureName(items[index].name) : nil
        })
        let removedNames = removedAIItemNames[recordID, default: []]
        let candidates = responseItems.enumerated().filter {
            let name = normalizedCaptureName($0.element.name)
            return !protectedNames.contains(name) && !removedNames.contains(name)
        }
        let lastRecordIndex = existingIndices.last!
        var candidateOffset = 0
        var rebuilt: [CapturePlateItem] = []
        rebuilt.reserveCapacity(items.count + candidates.count)

        for index in items.indices {
            let item = items[index]
            guard item.aiRecordID == recordID else {
                rebuilt.append(item)
                continue
            }
            if item.userEdited {
                rebuilt.append(item)
            } else if candidateOffset < candidates.count {
                let candidate = candidates[candidateOffset]
                rebuilt.append(captureItem(from: candidate.element, id: item.id, recordID: recordID))
                candidateOffset += 1
            }
            if index == lastRecordIndex {
                while candidateOffset < candidates.count {
                    let candidate = candidates[candidateOffset]
                    rebuilt.append(captureItem(from: candidate.element, id: newItemIDs[candidate.offset], recordID: recordID))
                    candidateOffset += 1
                }
            }
        }
        items = rebuilt
    }

    private func captureItem(from item: AICaptureItem, id: UUID, recordID: UUID) -> CapturePlateItem {
        CapturePlateItem(
            id: id,
            name: item.name,
            quantityGrams: item.estPortionGrams,
            nutrition: NutritionValues(
                kcal: Kilocalories(item.kcal),
                protein: Grams(item.protein),
                carbs: Grams(item.carbs),
                fat: Grams(item.fat)
            ),
            provenance: .aiEstimate,
            aiRecordID: recordID,
            confidence: item.confidence,
            userEdited: false
        )
    }
}

public enum AICaptureRunner {
    /// Runs only meal records. Use ``runLabel(provider:recordID:on:)`` for label records.
    public static func run(
        provider: some AICaptureProvider,
        recordID: UUID,
        newItemIDs: [UUID],
        on plate: inout CapturePlate
    ) async {
        guard let record = plate.records.first(where: { $0.id == recordID }), record.kind == .meal,
              let data = await responseData(provider: provider, record: record, recordID: recordID, on: &plate)
        else { return }
        plate.applyResponse(data, toRecord: recordID, newItemIDs: newItemIDs)
    }

    /// Runs a label record and returns its draft without adding an item to the plate.
    public static func runLabel(
        provider: some AICaptureProvider,
        recordID: UUID,
        on plate: inout CapturePlate
    ) async -> FoodItemDraft? {
        guard let record = plate.records.first(where: { $0.id == recordID }), record.kind == .label,
              let data = await responseData(provider: provider, record: record, recordID: recordID, on: &plate)
        else { return nil }
        return plate.applyLabelResponse(data, toRecord: recordID)
    }

    private static func responseData(
        provider: some AICaptureProvider,
        record: AIEstimationRecordData,
        recordID: UUID,
        on plate: inout CapturePlate
    ) async -> Data? {
        let request = AICaptureRequest(
            kind: record.kind,
            photoID: record.photoID,
            hint: record.hint,
            corrections: record.userCorrections
        )
        do {
            let data = try await provider.estimate(request)
            guard !Task.isCancelled else { return nil }
            updateProviderMetadata(recordID: recordID, provider: provider, on: &plate)
            return data
        } catch let error as AICaptureProviderError where error == .offline {
            return nil
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return nil }
            updateProviderMetadata(recordID: recordID, provider: provider, on: &plate)
            guard let index = plate.records.firstIndex(where: { $0.id == recordID }) else { return nil }
            plate.failRecord(at: index, with: .providerFailed)
            return nil
        }
    }

    private static func updateProviderMetadata(
        recordID: UUID,
        provider: some AICaptureProvider,
        on plate: inout CapturePlate
    ) {
        guard let index = plate.records.firstIndex(where: { $0.id == recordID }) else { return }
        plate.records[index].providerTier = provider.tier
        plate.records[index].modelID = provider.modelID
    }
}

private func normalizedCaptureName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
