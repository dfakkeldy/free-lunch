// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #6: FreeLunchSchemaV1 is registered with an empty
// migration plan, and every container is instantiated through that plan.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §1 acceptance #6: migration scaffold")
struct SchemaMigrationTests {
    /// Every spec §1 entity plus the watch digest and outbox, by entity name.
    let expectedEntities: Set<String> = [
        "FoodItem", "Recipe", "RecipeComponent", "MealEntry", "MealItem",
        "AIEstimationRecord", "PhotoAttachment", "ShotEvent", "MedicationProfile",
        "SideEffectEntry", "WeightSampleMirror", "Correction", "PlannedShot",
        "PlannedMeal", "JournalEntry", "FormulaVersion", "TargetPeriod",
        "RecentFoodSnapshot", "WatchOutboxRecord"
    ]

    @Test("FreeLunchSchemaV1 is version 1.0.0 and lists every entity once")
    func schemaV1() {
        #expect(FreeLunchSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        let names = FreeLunchSchemaV1.models.map { String(describing: $0) }
        #expect(names.count == expectedEntities.count)
        #expect(Set(names) == expectedEntities)
    }

    @Test("the migration plan registers exactly V1 with no stages")
    func planShape() {
        let schemas = FreeLunchMigrationPlan.schemas
        #expect(schemas.count == 1)
        #expect(schemas.first.map { ObjectIdentifier($0) } == ObjectIdentifier(FreeLunchSchemaV1.self))
        #expect(FreeLunchMigrationPlan.stages.isEmpty)
    }

    @Test("phone and watch containers are built through the plan", arguments: FreeLunchStoreKind.allCases)
    func containerUsesPlan(kind: FreeLunchStoreKind) throws {
        let container = try FreeLunchContainer.make(kind, at: .inMemory)
        let plan = try #require(container.migrationPlan)
        #expect(ObjectIdentifier(plan) == ObjectIdentifier(FreeLunchMigrationPlan.self))
        #expect(Set(container.schema.entities.map(\.name)) == expectedEntities)
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
