// SPDX-License-Identifier: GPL-3.0-or-later
// FreeLunchSchemaV2 — the v1 schema plus DietarySampleMirror (the spec §1
// amendment declared in §10). V1 shipped to TestFlight, so its models are
// frozen and this version is an append: FreeLunchMigrationPlan migrates V1
// stores to it.
//
// A versioned schema is a complete snapshot, not a diff, so every model is
// declared again here as a nested copy. Nothing in this file names a V1
// type; the V1 originals stay in Models/ and must not change.
//
// Open until a V2 build ships: later tasks may append to this version
// (new models, new optional attributes) for as long as no build carrying V2
// has gone to TestFlight or the App Store. After that V2 is frozen too, and
// changes go to a FreeLunchSchemaV3 with its own migration stage.
//
// Internal, like V1: callers see FLCore value types through the store.
import FLCore
import Foundation
import SwiftData

enum FreeLunchSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    /// V1's entities in V1's order, then the V2 additions.
    static var models: [any PersistentModel.Type] {
        [
            FoodItem.self,
            Recipe.self,
            RecipeComponent.self,
            MealEntry.self,
            MealItem.self,
            AIEstimationRecord.self,
            PhotoAttachment.self,
            ShotEvent.self,
            MedicationProfile.self,
            SideEffectEntry.self,
            WeightSampleMirror.self,
            Correction.self,
            PlannedShot.self,
            PlannedMeal.self,
            JournalEntry.self,
            FormulaVersion.self,
            TargetPeriod.self,
            RecentFoodSnapshot.self,
            WatchOutboxRecord.self,
            DietarySampleMirror.self
        ]
    }
}

// MARK: - Catalog (spec §1 FoodItem, Recipe)
// Copied from V1 (Models/FoodModels.swift).

extension FreeLunchSchemaV2 {
    @Model
    final class FoodItem {
        @Attribute(.unique) var id: UUID
        var name: String
        var brand: String?
        // Canonical nutrition per 100 g.
        var kcal: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var fiberG: Double?
        var isLiquid: Bool
        var servingsJSON: Data
        var origin: FoodOrigin
        // Typeahead denormalization, maintained at log time.
        var useCount: Int
        var lastUsedAt: Date?
        var lastPortionGrams: Double?
        var archivedAt: Date?

        @Relationship(deleteRule: .deny, inverse: \MealItem.foodItem)
        var mealItems: [MealItem] = []
        @Relationship(deleteRule: .deny, inverse: \RecipeComponent.foodItem)
        var recipeComponents: [RecipeComponent] = []

        init(
            id: UUID,
            name: String,
            brand: String?,
            kcal: Double,
            proteinG: Double,
            carbsG: Double,
            fatG: Double,
            fiberG: Double?,
            isLiquid: Bool,
            servingsJSON: Data,
            origin: FoodOrigin,
            useCount: Int,
            lastUsedAt: Date?,
            lastPortionGrams: Double?,
            archivedAt: Date?
        ) {
            self.id = id
            self.name = name
            self.brand = brand
            self.kcal = kcal
            self.proteinG = proteinG
            self.carbsG = carbsG
            self.fatG = fatG
            self.fiberG = fiberG
            self.isLiquid = isLiquid
            self.servingsJSON = servingsJSON
            self.origin = origin
            self.useCount = useCount
            self.lastUsedAt = lastUsedAt
            self.lastPortionGrams = lastPortionGrams
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class Recipe {
        @Attribute(.unique) var id: UUID
        var name: String
        /// Canonical grams of the cooked result.
        var yieldGrams: Double
        @Relationship(deleteRule: .cascade, inverse: \RecipeComponent.recipe)
        var components: [RecipeComponent] = []

        init(id: UUID, name: String, yieldGrams: Double) {
            self.id = id
            self.name = name
            self.yieldGrams = yieldGrams
        }
    }

    @Model
    final class RecipeComponent {
        @Attribute(.unique) var id: UUID
        var order: Int
        /// Canonical raw grams.
        var grams: Double
        var foodItem: FoodItem?
        var recipe: Recipe?

        init(id: UUID, order: Int, grams: Double, foodItem: FoodItem?) {
            self.id = id
            self.order = order
            self.grams = grams
            self.foodItem = foodItem
        }
    }
}

// MARK: - Plate (spec §1 MealEntry, MealItem, AIEstimationRecord, PhotoAttachment)
// Copied from V1 (Models/MealModels.swift).

extension FreeLunchSchemaV2 {
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

// MARK: - GLP-1 lane (spec §1 ShotEvent, MedicationProfile, SideEffectEntry)
// Copied from V1 (Models/MedicationModels.swift).

extension FreeLunchSchemaV2 {
    @Model
    final class ShotEvent {
        @Attribute(.unique) var id: UUID
        /// Actual injection time.
        var takenAt: Date
        /// Canonical milligrams.
        var doseMg: Double
        var medication: MedicationProfile?
        var siteRaw: String?
        var note: String?
        var source: ShotSource

        init(
            id: UUID,
            takenAt: Date,
            doseMg: Double,
            medication: MedicationProfile?,
            siteRaw: String?,
            note: String?,
            source: ShotSource
        ) {
            self.id = id
            self.takenAt = takenAt
            self.doseMg = doseMg
            self.medication = medication
            self.siteRaw = siteRaw
            self.note = note
            self.source = source
        }
    }

    @Model
    final class MedicationProfile {
        @Attribute(.unique) var id: UUID
        var name: String
        var halfLifeHours: Double
        var tmaxHours: Double
        var intervalDays: Int
        var archivedAt: Date?
        @Relationship(deleteRule: .deny, inverse: \ShotEvent.medication)
        var shots: [ShotEvent] = []

        init(
            id: UUID,
            name: String,
            halfLifeHours: Double,
            tmaxHours: Double,
            intervalDays: Int,
            archivedAt: Date?
        ) {
            self.id = id
            self.name = name
            self.halfLifeHours = halfLifeHours
            self.tmaxHours = tmaxHours
            self.intervalDays = intervalDays
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class SideEffectEntry {
        @Attribute(.unique) var id: UUID
        var occurredAt: Date
        /// SideEffectType case name; `otherText` carries `.other`'s text.
        var typeKind: String
        var otherText: String?
        var severity: Int
        var note: String?

        init(
            id: UUID,
            occurredAt: Date,
            typeKind: String,
            otherText: String?,
            severity: Int,
            note: String?
        ) {
            self.id = id
            self.occurredAt = occurredAt
            self.typeKind = typeKind
            self.otherText = otherText
            self.severity = severity
            self.note = note
        }
    }
}

// MARK: - Weight lane (spec §1 WeightSampleMirror, Correction)
// Copied from V1 (Models/WeightModels.swift).

extension FreeLunchSchemaV2 {
    @Model
    final class WeightSampleMirror {
        @Attribute(.unique) var hkUUID: UUID
        var measuredAt: Date
        /// Canonical kilograms.
        var weightKg: Double
        var sourceBundleID: String
        var deletedInHK: Bool

        init(hkUUID: UUID, measuredAt: Date, weightKg: Double, sourceBundleID: String, deletedInHK: Bool) {
            self.hkUUID = hkUUID
            self.measuredAt = measuredAt
            self.weightKg = weightKg
            self.sourceBundleID = sourceBundleID
            self.deletedInHK = deletedInHK
        }
    }

    @Model
    final class Correction {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var targetKind: CorrectionTargetKind
        /// HealthKit UUID or entity UUID, as a string.
        var targetID: String
        var action: CorrectionAction
        /// Codable replacement payload for `.replace`.
        var replacement: Data?
        var reason: String?

        init(
            id: UUID,
            createdAt: Date,
            targetKind: CorrectionTargetKind,
            targetID: String,
            action: CorrectionAction,
            replacement: Data?,
            reason: String?
        ) {
            self.id = id
            self.createdAt = createdAt
            self.targetKind = targetKind
            self.targetID = targetID
            self.action = action
            self.replacement = replacement
            self.reason = reason
        }
    }
}

// MARK: - Planner and journal (spec §1 PlannedShot / PlannedMeal, JournalEntry)
// Copied from V1 (Models/PlannerModels.swift).

extension FreeLunchSchemaV2 {
    @Model
    final class PlannedShot {
        @Attribute(.unique) var id: UUID
        var plannedAt: Date
        var notificationID: String?
        var status: PlanStatus
        var fulfilledBy: UUID?
        /// Canonical milligrams.
        var doseMg: Double?

        init(
            id: UUID,
            plannedAt: Date,
            notificationID: String?,
            status: PlanStatus,
            fulfilledBy: UUID?,
            doseMg: Double?
        ) {
            self.id = id
            self.plannedAt = plannedAt
            self.notificationID = notificationID
            self.status = status
            self.fulfilledBy = fulfilledBy
            self.doseMg = doseMg
        }
    }

    @Model
    final class PlannedMeal {
        @Attribute(.unique) var id: UUID
        var plannedAt: Date
        var notificationID: String?
        var status: PlanStatus
        var fulfilledBy: UUID?
        var name: String
        var note: String?

        init(
            id: UUID,
            plannedAt: Date,
            notificationID: String?,
            status: PlanStatus,
            fulfilledBy: UUID?,
            name: String,
            note: String?
        ) {
            self.id = id
            self.plannedAt = plannedAt
            self.notificationID = notificationID
            self.status = status
            self.fulfilledBy = fulfilledBy
            self.name = name
            self.note = note
        }
    }

    @Model
    final class JournalEntry {
        @Attribute(.unique) var id: UUID
        var at: Date
        var text: String
        @Relationship(deleteRule: .cascade, inverse: \PhotoAttachment.journalEntry)
        var photos: [PhotoAttachment] = []

        init(id: UUID, at: Date, text: String) {
            self.id = id
            self.at = at
            self.text = text
        }
    }
}

// MARK: - Targets (spec §1 TargetPeriod / FormulaVersion)
// Copied from V1 (Models/TargetModels.swift).

extension FreeLunchSchemaV2 {
    @Model
    final class FormulaVersion {
        @Attribute(.unique) var id: UUID
        var name: String
        /// Constrained expression DSL (spec §4).
        var definition: String
        var createdAt: Date
        /// FormulaOrigin case name; `builtinID` carries `.builtin`'s value.
        var originKind: String
        var builtinID: String?
        /// The version's parameters (ρ today) as JSON. Spec §4 gives every
        /// version its own params and spec §3 pins the whole version, so they
        /// live on the row; nil only on rows written before this column.
        var paramsJSON: Data?
        @Relationship(deleteRule: .deny, inverse: \TargetPeriod.formulaVersion)
        var periods: [TargetPeriod] = []

        init(
            id: UUID,
            name: String,
            definition: String,
            createdAt: Date,
            originKind: String,
            builtinID: String?,
            paramsJSON: Data? = nil
        ) {
            self.id = id
            self.name = name
            self.definition = definition
            self.createdAt = createdAt
            self.originKind = originKind
            self.builtinID = builtinID
            self.paramsJSON = paramsJSON
        }
    }

    @Model
    final class TargetPeriod {
        @Attribute(.unique) var id: UUID
        var startDate: Date
        var endDate: Date?
        // The three separate values (spec §1), canonical kcal.
        var expenditureAtAdoptionKcal: Double
        var calculatedTargetKcal: Double
        var adoptedTargetKcal: Double
        var proteinTargetG: Double
        var fatFloorPct: Double
        var formulaVersion: FormulaVersion?

        init(
            id: UUID,
            startDate: Date,
            endDate: Date?,
            expenditureAtAdoptionKcal: Double,
            calculatedTargetKcal: Double,
            adoptedTargetKcal: Double,
            proteinTargetG: Double,
            fatFloorPct: Double,
            formulaVersion: FormulaVersion?
        ) {
            self.id = id
            self.startDate = startDate
            self.endDate = endDate
            self.expenditureAtAdoptionKcal = expenditureAtAdoptionKcal
            self.calculatedTargetKcal = calculatedTargetKcal
            self.adoptedTargetKcal = adoptedTargetKcal
            self.proteinTargetG = proteinTargetG
            self.fatFloorPct = fatFloorPct
            self.formulaVersion = formulaVersion
        }
    }
}

// MARK: - Watch working set (spec §1 RecentFoodSnapshot)
// Copied from V1 (Models/WatchModels.swift).

extension FreeLunchSchemaV2 {
    @Model
    final class RecentFoodSnapshot {
        @Attribute(.unique) var foodID: UUID
        var name: String
        /// Canonical grams; the watch tap-to-log default portion.
        var lastPortionGrams: Double?
        /// Zero-based position in the phone's digest, with lower ranks first.
        var rank: Int

        init(foodID: UUID, name: String, lastPortionGrams: Double?, rank: Int) {
            self.foodID = foodID
            self.name = name
            self.lastPortionGrams = lastPortionGrams
            self.rank = rank
        }
    }
}

// MARK: - Watch outbox
// Copied from V1 (Models/WatchOutboxModels.swift).

extension FreeLunchSchemaV2 {
    @Model
    final class WatchOutboxRecord {
        @Attribute(.unique) var id: UUID
        /// Stored raw so the persistent schema does not depend on enum coding.
        var kindRaw: String
        var subjectID: UUID
        var queuedAt: Date
        var payload: Data

        init(id: UUID, kind: WatchOutboxKind, subjectID: UUID, queuedAt: Date, payload: Data) {
            self.id = id
            kindRaw = kind.rawValue
            self.subjectID = subjectID
            self.queuedAt = queuedAt
            self.payload = payload
        }

        var kind: WatchOutboxKind? {
            WatchOutboxKind(rawValue: kindRaw)
        }
    }
}

// MARK: - V2 additions
// Nutrition lane (spec §1 amendment): DietarySampleMirror.

extension FreeLunchSchemaV2 {
    /// A local cache of one HealthKit dietary sample, the same shape as
    /// WeightSampleMirror. HealthKit is canonical; the anchored queries that
    /// maintain this mirror and the reconstruction rules that read it are
    /// spec §10.
    @Model
    final class DietarySampleMirror {
        @Attribute(.unique) var hkUUID: UUID
        var date: Date
        /// Canonical kilocalories.
        var kcal: Double
        /// Canonical grams; nil when the sample carries no value.
        var proteinG: Double?
        var carbsG: Double?
        var fatG: Double?
        var sourceBundleID: String
        var deletedInHK: Bool

        init(
            hkUUID: UUID,
            date: Date,
            kcal: Double,
            proteinG: Double?,
            carbsG: Double?,
            fatG: Double?,
            sourceBundleID: String,
            deletedInHK: Bool
        ) {
            self.hkUUID = hkUUID
            self.date = date
            self.kcal = kcal
            self.proteinG = proteinG
            self.carbsG = carbsG
            self.fatG = fatG
            self.sourceBundleID = sourceBundleID
            self.deletedInHK = deletedInHK
        }
    }
}
