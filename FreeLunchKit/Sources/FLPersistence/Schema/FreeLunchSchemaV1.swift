// SPDX-License-Identifier: GPL-3.0-or-later
// FreeLunchSchemaV1 — the v1 SwiftData schema (spec §1), registered as a
// `VersionedSchema` with an empty migration plan from day one, so v2 is an
// append rather than a retrofit.
//
// The schema owns its models: each is declared under Models/ as
// `extension FreeLunchSchemaV1 { @Model final class … }`, so `models` below
// names this version's types and a later version cannot edit them out from
// under it. Schema/CurrentSchema.swift maps the plain names (`FoodItem`,
// `MealEntry`…) to the current version for the rest of the module.
//
// Internal, not public: nothing outside FLPersistence may name a `@Model`
// type. Callers see FLCore value types through `FreeLunchStore`.
//
// One schema serves both devices. The phone keeps full history; the watch
// keeps a working set (spec §1 store shape). That difference is content
// policy, not a different entity set, so there is one migration ladder.
//
// Once v1 ships, the declarations in Models/ are frozen: v2 gets its own
// nested copies in its own file (see CurrentSchema.swift).
import Foundation
import SwiftData

enum FreeLunchSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// Every spec §1 entity, in spec order, then the watch working-set
    /// digest. The watch outbox is not modelled yet; it lands with the
    /// watch pruning work.
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
            RecentFoodSnapshot.self
        ]
    }
}
