// SPDX-License-Identifier: GPL-3.0-or-later
// Plate models (spec §1 MealEntry, MealItem, AIEstimationRecord,
// PhotoAttachment).
//
// Deleting a MealEntry cascades to its items and photos. A MealItem's
// nutrition columns are the log-time snapshot; nothing ever rewrites them
// from the FoodItem it points to.
import FLCore
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class MealEntry {
        @Attribute(.unique) var id: UUID
        var state: MealState
        var createdAt: Date
        var loggedAt: Date?
        @Relationship(deleteRule: .cascade, inverse: \MealItem.meal)
        var items: [MealItem] = []
        var hunger: Int?
        var note: String?
        @Relationship(deleteRule: .cascade, inverse: \PhotoAttachment.meal)
        var photos: [PhotoAttachment] = []
        var source: MealSource

        init(
            id: UUID,
            state: MealState,
            createdAt: Date,
            loggedAt: Date?,
            hunger: Int?,
            note: String?,
            source: MealSource
        ) {
            self.id = id
            self.state = state
            self.createdAt = createdAt
            self.loggedAt = loggedAt
            self.hunger = hunger
            self.note = note
            self.source = source
        }
    }

    @Model
    final class MealItem {
        @Attribute(.unique) var id: UUID
        var order: Int
        /// Provenance only; nil for an ad-hoc item.
        var foodItem: FoodItem?
        var adHocName: String?
        var quantityGrams: Double
        // Log-time nutrition snapshot for quantityGrams (canonical truth).
        var kcal: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var fiberG: Double?
        var provenance: ItemProvenance
        var aiRecord: AIEstimationRecord?
        var confidence: Double?
        var meal: MealEntry?

        init(
            id: UUID,
            order: Int,
            foodItem: FoodItem?,
            adHocName: String?,
            quantityGrams: Double,
            kcal: Double,
            proteinG: Double,
            carbsG: Double,
            fatG: Double,
            fiberG: Double?,
            provenance: ItemProvenance,
            aiRecord: AIEstimationRecord?,
            confidence: Double?
        ) {
            self.id = id
            self.order = order
            self.foodItem = foodItem
            self.adHocName = adHocName
            self.quantityGrams = quantityGrams
            self.kcal = kcal
            self.proteinG = proteinG
            self.carbsG = carbsG
            self.fatG = fatG
            self.fiberG = fiberG
            self.provenance = provenance
            self.aiRecord = aiRecord
            self.confidence = confidence
        }
    }

    @Model
    final class AIEstimationRecord {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var photo: PhotoAttachment?
        var hint: String?
        var providerTier: Int
        var modelID: String
        var status: AIEstimationStatus
        var responseJSON: Data?
        var userCorrections: [String]
        @Relationship(deleteRule: .nullify, inverse: \MealItem.aiRecord)
        var items: [MealItem] = []

        init(
            id: UUID,
            createdAt: Date,
            photo: PhotoAttachment?,
            hint: String?,
            providerTier: Int,
            modelID: String,
            status: AIEstimationStatus,
            responseJSON: Data?,
            userCorrections: [String]
        ) {
            self.id = id
            self.createdAt = createdAt
            self.photo = photo
            self.hint = hint
            self.providerTier = providerTier
            self.modelID = modelID
            self.status = status
            self.responseJSON = responseJSON
            self.userCorrections = userCorrections
        }
    }

    @Model
    final class PhotoAttachment {
        @Attribute(.unique) var id: UUID
        var relativePath: String
        var capturedAt: Date
        var kind: PhotoKind
        var meal: MealEntry?
        var journalEntry: JournalEntry?
        @Relationship(deleteRule: .nullify, inverse: \AIEstimationRecord.photo)
        var aiRecords: [AIEstimationRecord] = []

        init(id: UUID, relativePath: String, capturedAt: Date, kind: PhotoKind) {
            self.id = id
            self.relativePath = relativePath
            self.capturedAt = capturedAt
            self.kind = kind
        }
    }
}
