// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #6: the versioned schemas are registered on one
// append-only migration plan (V1, then V2 with the DietarySampleMirror
// amendment and the energy-settings entities), and every container is
// instantiated through that plan. The V1 → V2 stage itself is proven on a
// seeded store in SchemaV1ToV2MigrationTests.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §1 acceptance #6: migration scaffold")
struct SchemaMigrationTests {
    /// V1: every spec §1 entity plus the watch digest and outbox, by name.
    let v1Entities: Set<String> = [
        "FoodItem", "Recipe", "RecipeComponent", "MealEntry", "MealItem",
        "AIEstimationRecord", "PhotoAttachment", "ShotEvent", "MedicationProfile",
        "SideEffectEntry", "WeightSampleMirror", "Correction", "PlannedShot",
        "PlannedMeal", "JournalEntry", "FormulaVersion", "TargetPeriod",
        "RecentFoodSnapshot", "WatchOutboxRecord"
    ]

    /// V2: V1 plus the spec §1 amendment and the energy-settings pair.
    var v2Entities: Set<String> {
        v1Entities.union(["DietarySampleMirror", "EnergySettingsRecord", "DidNotTrackMark"])
    }

    @Test("FreeLunchSchemaV1 is version 1.0.0 and lists every entity once")
    func schemaV1() {
        #expect(FreeLunchSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        let names = FreeLunchSchemaV1.models.map { String(describing: $0) }
        #expect(names.count == v1Entities.count)
        #expect(Set(names) == v1Entities)
    }

    @Test("FreeLunchSchemaV2 is version 2.0.0 and lists V1's entities plus its three additions once")
    func schemaV2() {
        #expect(FreeLunchSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        let names = FreeLunchSchemaV2.models.map { String(describing: $0) }
        #expect(names.count == v2Entities.count)
        #expect(Set(names) == v2Entities)
        // A complete snapshot: no V1 class is reused by V2.
        let v1Types = Set(FreeLunchSchemaV1.models.map { ObjectIdentifier($0) })
        #expect(FreeLunchSchemaV2.models.allSatisfy { !v1Types.contains(ObjectIdentifier($0)) })
    }

    @Test("the current schema is V2")
    func currentIsV2() {
        #expect(ObjectIdentifier(FreeLunchSchemaCurrent.self) == ObjectIdentifier(FreeLunchSchemaV2.self))
        #expect(ObjectIdentifier(FoodItem.self) == ObjectIdentifier(FreeLunchSchemaV2.FoodItem.self))
        #expect(ObjectIdentifier(DietarySampleMirror.self) == ObjectIdentifier(FreeLunchSchemaV2.DietarySampleMirror.self))
        #expect(ObjectIdentifier(EnergySettingsRecord.self) == ObjectIdentifier(FreeLunchSchemaV2.EnergySettingsRecord.self))
        #expect(ObjectIdentifier(DidNotTrackMark.self) == ObjectIdentifier(FreeLunchSchemaV2.DidNotTrackMark.self))
    }

    @Test("the migration plan registers V1 then V2 with one stage")
    func planShape() {
        let schemas = FreeLunchMigrationPlan.schemas.map { ObjectIdentifier($0) }
        #expect(schemas == [ObjectIdentifier(FreeLunchSchemaV1.self), ObjectIdentifier(FreeLunchSchemaV2.self)])
        #expect(FreeLunchMigrationPlan.stages.count == 1)
    }

    @Test("phone and watch containers are built through the plan", arguments: FreeLunchStoreKind.allCases)
    func containerUsesPlan(kind: FreeLunchStoreKind) throws {
        let container = try FreeLunchContainer.make(kind, at: .inMemory)
        let plan = try #require(container.migrationPlan)
        #expect(ObjectIdentifier(plan) == ObjectIdentifier(FreeLunchMigrationPlan.self))
        #expect(Set(container.schema.entities.map(\.name)) == v2Entities)
        #expect(container.configurations.first?.name == kind.storeName)
    }

    @Test("a store file created under the plan reopens under the plan")
    func reopenThroughPlan() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let food = FoodItemData(id: uid(1), name: "Synthetic", per100g: nutrition(100, 1, 1, 1), origin: .custom)
        do {
            let store = try SwiftDataStore.watch(at: .file(url))
            try store.createFood(food)
        }
        let reopened = try FreeLunchContainer.make(.watch, at: .file(url))
        #expect(reopened.migrationPlan.map { ObjectIdentifier($0) } == ObjectIdentifier(FreeLunchMigrationPlan.self))
        #expect(try SwiftDataStore(container: reopened).food(id: uid(1)) == food)
    }

    @Test("the default store path is per device and inside a FreeLunch folder")
    func defaultPath() throws {
        let phone = try FreeLunchContainer.defaultStoreURL(for: .phone)
        let watch = try FreeLunchContainer.defaultStoreURL(for: .watch)
        #expect(phone.lastPathComponent == "FreeLunch-phone.store")
        #expect(watch.lastPathComponent == "FreeLunch-watch.store")
        #expect(phone.deletingLastPathComponent().lastPathComponent == "FreeLunch")
    }
}
