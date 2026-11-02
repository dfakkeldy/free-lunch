// SPDX-License-Identifier: GPL-3.0-or-later
// Pure conversion between the in-memory capture plate and FLCore persistence values.
import FLCore
import Foundation

extension CapturePlate {
    /// The supplied attachments are the persisted source of truth for capture kind;
    /// this mapping deliberately does not reconcile an in-memory record's `kind`.
    /// Attachments not referenced by a record are intentionally omitted.
    public func snapshot(photos: [PhotoAttachmentData]) -> AICaptureSnapshot {
        let recordPhotoIDs = Set(records.compactMap(\.photoID))
        // Label drafts have no record until persistence. Link them to the newest
        // label record; if there is none, they are not AI-capture snapshot items.
        let latestLabelRecordID = records
            .filter { $0.kind == .label }
            .max { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }?
            .id
        let storedRecords = records.map {
            StoredAIEstimationRecordData(
                id: $0.id,
                createdAt: $0.createdAt,
                photoID: $0.photoID,
                hint: $0.hint,
                providerTier: $0.providerTier,
                modelID: $0.modelID,
                status: $0.status,
                responseJSON: $0.responseJSON,
                userCorrections: $0.userCorrections
            )
        }
        let storedItems = items.enumerated().compactMap { index, item -> MealItemData? in
            let recordID = item.aiRecordID
                ?? (item.provenance == .labelOCR ? latestLabelRecordID : nil)
            guard let recordID else { return nil }
            return MealItemData(
                id: item.id,
                order: index,
                foodID: nil,
                adHocName: item.name,
                quantity: Grams(item.quantityGrams),
                nutrition: item.nutrition,
                provenance: item.provenance,
                aiRecordID: recordID,
                confidence: item.confidence
            )
        }
        return AICaptureSnapshot(
            photos: photos.filter { recordPhotoIDs.contains($0.id) },
            records: storedRecords,
            items: storedItems
        )
    }

    /// Removed response names are recovered from completed meal records. A user rename
    /// also suppresses the original response name on a later provider rerun.
    public init(snapshot: AICaptureSnapshot, state: MealState = .draft) {
        let photos = Dictionary(
            snapshot.photos.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let loadedRecords = snapshot.records.map { record in
            let kind = record.photoID.flatMap { photos[$0]?.kind } ?? .meal
            let failure: AICaptureFailure?
            if record.status == .failed {
                if let responseJSON = record.responseJSON,
                   case .failure(let parsedFailure) = AICaptureParser.parse(responseJSON) {
                    failure = parsedFailure
                } else {
                    failure = .providerFailed
                }
            } else {
                failure = nil
            }
            return AIEstimationRecordData(
                id: record.id,
                createdAt: record.createdAt,
                photoID: record.photoID,
                kind: kind,
                hint: record.hint,
                providerTier: record.providerTier,
                modelID: record.modelID,
                status: record.status,
                responseJSON: record.responseJSON,
                userCorrections: record.userCorrections,
                failure: failure
            )
        }
        let recordsByID = Dictionary(
            loadedRecords.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.init(
            state: state,
            items: snapshot.items.sorted(by: MealItemData.displayOrder).map { item in
                CapturePlateItem(
                    id: item.id,
                    name: item.adHocName ?? "",
                    quantityGrams: item.quantityGrams,
                    nutrition: item.nutrition,
                    provenance: item.provenance,
                    aiRecordID: item.aiRecordID,
                    confidence: item.confidence,
                    userEdited: captureItemWasEdited(item, record: item.aiRecordID.flatMap { recordsByID[$0] })
                )
            },
            records: loadedRecords
        )
        for record in loadedRecords where record.kind == .meal && record.status == .complete {
            guard let responseJSON = record.responseJSON,
                  case .success(let response) = AICaptureParser.parse(responseJSON)
            else { continue }
            let loadedNames = Set(items.compactMap { item in
                item.aiRecordID == record.id ? normalized(item.name) : nil
            })
            let removedNames = Set(response.items.compactMap { item -> String? in
                let name = normalized(item.name)
                return loadedNames.contains(name) ? nil : name
            })
            if !removedNames.isEmpty {
                removedAIItemNames[record.id] = removedNames
            }
        }
    }
}

private func captureItemWasEdited(_ item: MealItemData, record: AIEstimationRecordData?) -> Bool {
    guard item.provenance == .aiEstimate else {
        return false
    }
    if item.nutrition.fiberG != nil {
        return true
    }
    guard record?.kind == .meal,
          let responseJSON = record?.responseJSON,
          case .success(let response) = AICaptureParser.parse(responseJSON)
    else {
        return false
    }
    return !response.items.contains { responseItem in
        normalized(responseItem.name) == normalized(item.adHocName ?? "")
            && responseItem.estPortionGrams == item.quantityGrams
            && approximatelyEqual(responseItem.kcal, item.nutrition.kcal)
            && approximatelyEqual(responseItem.protein, item.nutrition.proteinG)
            && approximatelyEqual(responseItem.carbs, item.nutrition.carbsG)
            && approximatelyEqual(responseItem.fat, item.nutrition.fatG)
    }
}

private func normalized(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
    abs(lhs - rhs) < 0.000_000_001
}
