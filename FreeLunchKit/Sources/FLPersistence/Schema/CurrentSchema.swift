// SPDX-License-Identifier: GPL-3.0-or-later
// The current-schema facade. Store code names `FoodItem`, never
// `FreeLunchSchemaV2.FoodItem`; this block decides which version that means.
// FreeLunchContainer builds its schema from `FreeLunchSchemaCurrent`.
//
// The procedure for a new version n (V2 followed it):
//  1. Add Schema/FreeLunchSchemaVn.swift with `enum FreeLunchSchemaVn:
//     VersionedSchema` holding a nested copy of every model (a versioned
//     schema is a complete snapshot, not a diff), with the change applied.
//     Do not reference an earlier version's types from it.
//  2. Append Vn and one MigrationStage to FreeLunchMigrationPlan.
//  3. Repoint the typealiases below. Nothing else names a version.

typealias FreeLunchSchemaCurrent = FreeLunchSchemaV2

typealias FoodItem = FreeLunchSchemaCurrent.FoodItem
typealias Recipe = FreeLunchSchemaCurrent.Recipe
typealias RecipeComponent = FreeLunchSchemaCurrent.RecipeComponent
typealias MealEntry = FreeLunchSchemaCurrent.MealEntry
typealias MealItem = FreeLunchSchemaCurrent.MealItem
typealias AIEstimationRecord = FreeLunchSchemaCurrent.AIEstimationRecord
typealias PhotoAttachment = FreeLunchSchemaCurrent.PhotoAttachment
typealias ShotEvent = FreeLunchSchemaCurrent.ShotEvent
typealias MedicationProfile = FreeLunchSchemaCurrent.MedicationProfile
typealias SideEffectEntry = FreeLunchSchemaCurrent.SideEffectEntry
typealias WeightSampleMirror = FreeLunchSchemaCurrent.WeightSampleMirror
typealias Correction = FreeLunchSchemaCurrent.Correction
typealias PlannedShot = FreeLunchSchemaCurrent.PlannedShot
typealias PlannedMeal = FreeLunchSchemaCurrent.PlannedMeal
typealias JournalEntry = FreeLunchSchemaCurrent.JournalEntry
typealias FormulaVersion = FreeLunchSchemaCurrent.FormulaVersion
typealias TargetPeriod = FreeLunchSchemaCurrent.TargetPeriod
typealias RecentFoodSnapshot = FreeLunchSchemaCurrent.RecentFoodSnapshot
typealias WatchOutboxRecord = FreeLunchSchemaCurrent.WatchOutboxRecord
typealias DietarySampleMirror = FreeLunchSchemaCurrent.DietarySampleMirror
typealias EnergySettingsRecord = FreeLunchSchemaCurrent.EnergySettingsRecord
typealias DidNotTrackMark = FreeLunchSchemaCurrent.DidNotTrackMark
