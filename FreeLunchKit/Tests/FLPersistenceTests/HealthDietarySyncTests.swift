// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation
import Testing
@testable import FLPersistence

@MainActor
@Suite("Dietary mirror and export boundary")
struct HealthDietarySyncTests {
    private typealias E = EnergyStoreFixture

    @Test("paged additions and deletions retain tombstones and resume anchors")
    func pages() async throws {
        let store = try makeInMemoryStore()
        let health = MockHealthStore()
        let anchors = MemoryAnchorStore()
        let sync = HealthDietarySync(health: health, dietary: store, meals: store, anchors: anchors, pageLimit: 1)
        let sample = DietarySampleData(hkUUID: uid(801), date: E.noon(2), energy: Kilocalories(123), sourceBundleID: "example.food")
        health.dietaryJournal = [.added(sample), .deleted(sample.hkUUID), .deleted(uid(899))]
        #expect(try await sync.sync() == .synced(upserted: 1, markedDeleted: 1, skipped: 0))
        #expect(try store.dietarySamples(from: E.day(2), through: E.day(2), calendar: E.calendar, includingDeletedInHK: true).first?.deletedInHK == true)
        #expect(try store.dayIntakes(through: E.day(2), calendar: E.calendar).isEmpty)
        #expect(try await sync.sync() == .synced(upserted: 0, markedDeleted: 0, skipped: 0))
        #expect(anchors.anchor(for: .bodyMass) == nil)
    }

    @Test("native log echoes into mirror but never reconstructs; edits replace and deletion removes exports")
    func echo() async throws {
        let store = try makeInMemoryStore()
        let health = MockHealthStore()
        health.sharing[.dietaryEnergyConsumed] = .sharingAuthorized
        let sync = HealthDietarySync(health: health, dietary: store, meals: store, anchors: MemoryAnchorStore(), pageLimit: 1)
        try store.createMeal(MealEntryData(id: uid(802), createdAt: E.noon(2), items: [
            MealItemData(id: uid(803), order: 0, foodID: nil, adHocName: "Synthetic food", quantity: Grams(100), nutrition: E.kcal(400), provenance: .typed)
        ], source: .phone))
        let meal = try await sync.logMeal(id: uid(802), at: E.noon(2))
        await sync.writeMeal(meal)
        #expect(health.dietaryMealIDs.count == 1)
        _ = try await sync.sync()
        #expect(try store.dietarySamples(from: E.day(2), through: E.day(2), calendar: E.calendar, includingDeletedInHK: true).count == 2)
        #expect(try store.reconstructedNutritionDays(from: E.day(2), through: E.day(2), calendar: E.calendar, ownSourceBundleID: health.ownSourceBundleID).isEmpty)
        #expect(try store.dayIntakes(through: E.day(2), calendar: E.calendar, ownSourceBundleID: health.ownSourceBundleID).first?.intakeKcal == 400)
        try await sync.deleteMeal(id: meal.id)
        _ = try await sync.sync()
        #expect(health.dietaryMealIDs.isEmpty)
        #expect(try store.dayIntakes(through: E.day(2), calendar: E.calendar, ownSourceBundleID: health.ownSourceBundleID).isEmpty)
    }

    @Test("failed replacement save preserves old export and a later retry replaces it")
    func failedEdit() async throws {
        let store = try makeInMemoryStore()
        let health = MockHealthStore()
        health.sharing[.dietaryEnergyConsumed] = .sharingAuthorized
        let sync = HealthDietarySync(health: health, dietary: store, meals: store, anchors: MemoryAnchorStore())
        try store.createMeal(MealEntryData(id: uid(811), createdAt: E.noon(2), source: .phone))
        var meal = try await sync.logMeal(id: uid(811), at: E.noon(2))
        let original = health.dietaryMealIDs.keys.first
        meal = try store.setLoggedAt(E.noon(3), mealID: meal.id)
        health.saveError = HealthAccessError.temporarilyUnavailable
        await sync.writeMeal(meal)
        #expect(health.dietaryMealIDs.keys.first == original)
        #expect(try store.meal(id: meal.id)?.loggedAt == E.noon(3))
        await sync.writeMeal(meal)
        #expect(health.dietaryMealIDs.count == 1)
        #expect(health.dietaryMealIDs.keys.first != original)
    }

    @Test("mirror and correction changes invalidate the coordinator key")
    func recompute() throws {
        let store = try makeInMemoryStore()
        let coordinator = EnergyRecomputeCoordinator(store: store, calendar: E.calendar,
            ownSourceBundleID: "example.own", today: E.day(3), historyFrom: E.day(1))
        let first = try coordinator.refresh()
        let sample = DietarySampleData(hkUUID: uid(812), date: E.noon(2), energy: Kilocalories(200), sourceBundleID: "example.food")
        try store.upsertDietarySample(sample)
        let imported = try coordinator.refresh()
        #expect(imported.key.intake != first.key.intake)
        try store.addCorrection(CorrectionData(createdAt: E.day(3), targetKind: .hkNutritionDay,
            targetID: CorrectedNutritionView.dayKey(E.day(2), calendar: E.calendar), action: .exclude))
        #expect(try coordinator.refresh().key.intake.isEmpty)
    }

    @Test("denied export leaves native logging intact")
    func denied() async throws {
        let store = try makeInMemoryStore()
        let health = MockHealthStore()
        let sync = HealthDietarySync(health: health, dietary: store, meals: store, anchors: MemoryAnchorStore())
        try store.createMeal(MealEntryData(id: uid(804), createdAt: E.noon(2), source: .phone))
        _ = try await sync.logMeal(id: uid(804), at: E.noon(2))
        #expect(try store.meal(id: uid(804))?.state == .logged)
        #expect(health.dietaryJournal.isEmpty)
    }

    @Test("legacy imported meals cannot manufacture reconstructed history")
    func legacySource() throws {
        let store = try makeInMemoryStore()
        try store.createMeal(MealEntryData(id: uid(813), state: .logged, createdAt: E.noon(2),
            loggedAt: E.noon(2), source: .healthKitImport))
        #expect(try store.dayIntakes(through: E.day(2), calendar: E.calendar).isEmpty)
    }

    @Test("corrections replace and exclude totals, validate payloads, and leave native days alone")
    func corrections() throws {
        let store = try makeInMemoryStore()
        try store.upsertDietarySample(DietarySampleData(hkUUID: uid(805), date: E.noon(2), energy: Kilocalories(200), sourceBundleID: "example.food"))
        let key = CorrectedNutritionView.dayKey(E.day(2), calendar: E.calendar)
        try store.addCorrection(CorrectionData(createdAt: E.day(3), targetKind: .hkNutritionDay, targetID: key, action: .replace,
            replacement: NutritionDayReplacement(energy: Kilocalories(350), protein: Grams(20)).encoded()))
        #expect(try store.dayIntakes(through: E.day(2), calendar: E.calendar).first?.intakeKcal == 350)
        #expect(try store.reconstructedNutritionDays(from: E.day(2), through: E.day(2), calendar: E.calendar).first?.totals.proteinG == 20)
        #expect(throws: WeightStoreError.self) {
            try store.addCorrection(CorrectionData(createdAt: E.day(3), targetKind: .hkNutritionDay, targetID: key, action: .replace, replacement: Data("{}".utf8)))
        }
        #expect(throws: WeightStoreError.self) {
            try store.addCorrection(CorrectionData(createdAt: E.day(3), targetKind: .hkNutritionDay, targetID: "2026-02-30", action: .exclude))
        }
        try store.addCorrection(CorrectionData(createdAt: E.day(4), targetKind: .hkNutritionDay, targetID: key, action: .exclude))
        #expect(try store.dayIntakes(through: E.day(2), calendar: E.calendar).isEmpty)
        try store.createMeal(MealEntryData(id: uid(814), state: .logged, createdAt: E.noon(2),
            loggedAt: E.noon(2), items: [MealItemData(id: uid(815), order: 0, foodID: nil,
                adHocName: "Synthetic food", quantity: Grams(100), nutrition: E.kcal(600), provenance: .typed)], source: .phone))
        let native = try store.dayIntakes(through: E.day(2), calendar: E.calendar)
        #expect(native.first?.intakeKcal == 600)
        #expect(native.first?.evidence.hasReconstructedDietaryEnergy == false)
    }
}
