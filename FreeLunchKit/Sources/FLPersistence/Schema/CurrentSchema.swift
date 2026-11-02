// SPDX-License-Identifier: GPL-3.0-or-later
// The current-schema facade. Store code names `FoodItem`, never
// `FreeLunchSchemaV1.FoodItem`; this block decides which version that means.
//
// The v2 procedure:
//  1. Add Schema/FreeLunchSchemaV2.swift with `enum FreeLunchSchemaV2:
//     VersionedSchema` holding a nested copy of every model (a versioned
//     schema is a complete snapshot, not a diff), with the v2 change
//     applied. Do not reference V1 types from V2.
//  2. Append V2 and one MigrationStage to FreeLunchMigrationPlan.
//  3. Point `Schema(versionedSchema:)` in FreeLunchContainer at V2.
//  4. Repoint the typealiases below. Nothing else names a version.

typealias FreeLunchSchemaCurrent = FreeLunchSchemaV1

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
