// SPDX-License-Identifier: GPL-3.0-or-later
// Persistence bridge between a draft CapturePlate snapshot and SwiftData.
import FLCore
import Foundation
import SwiftData

public enum AICaptureBridgeError: Error, Equatable, Sendable {
    case recordNeedsPhoto(UUID)
    case labelRecordNeedsPhoto(UUID)
    case immutableRecordPhoto(UUID)
    case invalidAIItem(UUID)
    case invalidQuantity(UUID)
    case invalidNutrition(UUID)
    case invalidConfidence(UUID)
}

@MainActor
public protocol AICaptureStore: PlateLifecycleStore {
    func saveAICapture(_ snapshot: AICaptureSnapshot, toMeal mealID: UUID) throws
    func aiCapture(forMeal mealID: UUID) throws -> AICaptureSnapshot
}

@MainActor
extension SwiftDataStore: AICaptureStore {
    public func saveAICapture(_ snapshot: AICaptureSnapshot, toMeal mealID: UUID) throws {
        try requireStoreKind(.phone, operation: "saveAICapture")
        let meal = try editableMeal(id: mealID)
        guard meal.state == .draft else { throw FreeLunchStoreError.mealNotDraft(mealID) }

        // Validate every relationship and value before changing the context.
        var snapshotPhotos: [UUID: PhotoAttachmentData] = [:]
        for photo in snapshot.photos {
            guard snapshotPhotos.updateValue(photo, forKey: photo.id) == nil else {
                throw FreeLunchStoreError.duplicateID(photo.id)
            }
            if let stored = try model(PhotoAttachment.self, id: photo.id), stored.meal?.id != mealID {
                throw FreeLunchStoreError.duplicateID(photo.id)
            }
        }

        var snapshotRecords: [UUID: AIEstimationRecordData] = [:]
        for record in snapshot.records {
            guard snapshotRecords.updateValue(record, forKey: record.id) == nil else {
                throw FreeLunchStoreError.duplicateID(record.id)
            }
            guard let photoID = record.photoID else {
                if recordIsLabel(record, items: snapshot.items) {
                    throw AICaptureBridgeError.labelRecordNeedsPhoto(record.id)
                }
                throw AICaptureBridgeError.recordNeedsPhoto(record.id)
            }
            if snapshotPhotos[photoID] == nil {
                guard let photo = try model(PhotoAttachment.self, id: photoID) else {
                    throw FreeLunchStoreError.missingPhoto(photoID)
                }
                guard photo.meal?.id == mealID else {
                    throw FreeLunchStoreError.duplicateID(photoID)
                }
            }
            if let stored = try model(AIEstimationRecord.self, id: record.id), stored.photo?.id != photoID {
                throw AICaptureBridgeError.immutableRecordPhoto(record.id)
            }
        }

        var incomingItemIDs: Set<UUID> = []
        var resolvedItemRecords: [UUID: AIEstimationRecord] = [:]
        for item in snapshot.items {
            guard incomingItemIDs.insert(item.id).inserted else {
                throw FreeLunchStoreError.duplicateID(item.id)
            }
            guard item.foodID == nil, item.adHocName != nil,
                  item.aiRecordID != nil,
                  item.provenance == .aiEstimate || item.provenance == .labelOCR
            else {
                throw AICaptureBridgeError.invalidAIItem(item.id)
            }
            try validate(item)
            guard let recordID = item.aiRecordID else { continue }
            if snapshotRecords[recordID] == nil,
               let stored = try model(AIEstimationRecord.self, id: recordID) {
                resolvedItemRecords[recordID] = stored
            } else if snapshotRecords[recordID] == nil {
                throw FreeLunchStoreError.missingAIRecord(recordID)
            }
            if let storedItem = try model(MealItem.self, id: item.id), storedItem.meal?.id != mealID {
                throw FreeLunchStoreError.duplicateID(item.id)
            }
        }

        // New photos are attached to this meal. Existing rows retain their path and kind.
        var resolvedPhotos: [UUID: PhotoAttachment] = [:]
        for photo in snapshot.photos {
            if let stored = try model(PhotoAttachment.self, id: photo.id) {
                resolvedPhotos[photo.id] = stored
            } else {
                let stored = PhotoAttachment(
                    id: photo.id,
                    relativePath: photo.relativePath,
                    capturedAt: photo.capturedAt,
                    kind: photo.kind
                )
                context.insert(stored)
                stored.meal = meal
                resolvedPhotos[photo.id] = stored
            }
        }
        for record in snapshot.records {
            guard let photoID = record.photoID else { continue }
            if resolvedPhotos[photoID] == nil,
               let stored = try model(PhotoAttachment.self, id: photoID) {
                resolvedPhotos[photoID] = stored
            }
        }

        // An incoming record has a photo by preflight. Existing record creation time
        // and photo link deliberately remain immutable.
        for record in snapshot.records {
            if let stored = try model(AIEstimationRecord.self, id: record.id) {
                stored.status = record.status
                stored.responseJSON = record.responseJSON
                stored.userCorrections = record.userCorrections
                stored.hint = record.hint
                stored.providerTier = record.providerTier
                stored.modelID = record.modelID
            } else {
                guard let photoID = record.photoID,
                      let photo = resolvedPhotos[photoID]
                else {
                    throw AICaptureBridgeError.recordNeedsPhoto(record.id)
                }
                let stored = AIEstimationRecord(
                    id: record.id,
                    createdAt: record.createdAt,
                    photo: photo,
                    hint: record.hint,
                    providerTier: record.providerTier,
                    modelID: record.modelID,
                    status: record.status,
                    responseJSON: record.responseJSON,
                    userCorrections: record.userCorrections
                )
                context.insert(stored)
                resolvedItemRecords[record.id] = stored
            }
        }

        let nextOrder = (meal.items.map(\.order).max() ?? -1) + 1
        var appended = 0
        for item in snapshot.items {
            guard let recordID = item.aiRecordID else { continue }
            let record = try resolvedItemRecords[recordID] ?? model(AIEstimationRecord.self, id: recordID)
            guard let record else { throw FreeLunchStoreError.missingAIRecord(recordID) }
            if let stored = try model(MealItem.self, id: item.id) {
                stored.adHocName = item.adHocName
                stored.quantityGrams = item.quantityGrams
                stored.kcal = item.nutrition.kcal
                stored.proteinG = item.nutrition.proteinG
                stored.carbsG = item.nutrition.carbsG
                stored.fatG = item.nutrition.fatG
                stored.fiberG = item.nutrition.fiberG
                stored.provenance = item.provenance
                stored.confidence = item.confidence
                stored.aiRecord = record
            } else {
                let stored = MealItem(
                    id: item.id,
                    order: nextOrder + appended,
                    foodItem: nil,
                    adHocName: item.adHocName,
                    quantityGrams: item.quantityGrams,
                    kcal: item.nutrition.kcal,
                    proteinG: item.nutrition.proteinG,
                    carbsG: item.nutrition.carbsG,
                    fatG: item.nutrition.fatG,
                    fiberG: item.nutrition.fiberG,
                    provenance: item.provenance,
                    aiRecord: record,
                    confidence: item.confidence
                )
                context.insert(stored)
                stored.meal = meal
                appended += 1
            }
        }

        for item in meal.items where item.aiRecord != nil && item.foodItem == nil && !incomingItemIDs.contains(item.id) {
            context.delete(item)
        }
        try commit()
    }

    public func aiCapture(forMeal mealID: UUID) throws -> AICaptureSnapshot {
        try requireStoreKind(.phone, operation: "aiCapture")
        guard let meal = try model(MealEntry.self, id: mealID) else {
            throw FreeLunchStoreError.notFound(mealID)
        }
        let records = Dictionary(
            (meal.photos.flatMap(\.aiRecords) + meal.items.compactMap(\.aiRecord)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let recordIDs = Set(records.map(\.id))
        let photos = meal.photos
            .filter { photo in photo.aiRecords.contains { recordIDs.contains($0.id) } }
            .map { $0.asData() }
            .sorted(by: PhotoAttachmentData.displayOrder)
        let items = meal.items
            .filter {
                $0.aiRecord != nil
                    && $0.foodItem == nil
                    && ($0.provenance == .aiEstimate || $0.provenance == .labelOCR)
            }
            .map { $0.asData() }
            .sorted(by: MealItemData.displayOrder)
        return AICaptureSnapshot(
            photos: photos,
            records: records.map { $0.asData() },
            items: items
        )
    }

    private func recordIsLabel(
        _ record: AIEstimationRecordData,
        items: [MealItemData]
    ) -> Bool {
        items.contains { $0.aiRecordID == record.id && $0.provenance == .labelOCR }
    }

    private func validate(_ item: MealItemData) throws {
        guard item.quantityGrams.isFinite, item.quantityGrams > 0 else {
            throw AICaptureBridgeError.invalidQuantity(item.id)
        }
        let nutrition = item.nutrition
        guard nutrition.kcal.isFinite, nutrition.kcal >= 0,
              nutrition.proteinG.isFinite, nutrition.proteinG >= 0,
              nutrition.carbsG.isFinite, nutrition.carbsG >= 0,
              nutrition.fatG.isFinite, nutrition.fatG >= 0,
              nutrition.fiberG?.isFinite ?? true,
              nutrition.fiberG.map({ $0 >= 0 }) ?? true
        else {
            throw AICaptureBridgeError.invalidNutrition(item.id)
        }
        guard item.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw AICaptureBridgeError.invalidConfidence(item.id)
        }
    }
}
