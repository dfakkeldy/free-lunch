// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #2: edit a FoodItem's macros after logging → the logged
// MealItem's snapshot is byte-identical and the day's recomputed totals are
// unchanged. Expected values are worked by hand in the comments; every one
// is exactly representable, so equality is bit-for-bit.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §1 acceptance #2: snapshot invariance")
struct SnapshotInvarianceTests {
    let granola = uid(110)
    let apple = uid(111)
    let breakfast = uid(210)
    let dinner = uid(220)
    let nextDay = uid(230)
    let granolaItem = uid(211)
    let appleItem = uid(212)
    let adHocItem = uid(213)

    /// Day 0 (UTC): breakfast 08:00 + dinner 18:00, both logged; a meal
    /// on day 1; and an unlogged draft on day 0 that must not count.
    func populate(_ store: some FreeLunchStore) throws {
        try store.createFood(FoodItemData(id: granola, name: "Granola", per100g: nutrition(250, 10, 30, 10, fiber: 5), origin: .custom))
        try store.createFood(FoodItemData(id: apple, name: "Apple", per100g: nutrition(52, 0.25, 14, 0.5), origin: .seeded))

        try store.createMeal(MealEntryData(id: breakfast, createdAt: at(hour: 0), source: .phone))
        // 150 g granola: 250·150/100 = 375 kcal, 15 P, 45 C, 15 F, 7.5 fiber.
        try store.addItem(.catalog(id: granolaItem, foodID: granola, quantity: Grams(150)), toMeal: breakfast)
        // 200 g apple: 52·200/100 = 104 kcal, 0.5 P, 28 C, 1 F, no fiber.
        try store.addItem(.catalog(id: appleItem, foodID: apple, quantity: Grams(200)), toMeal: breakfast)
        try store.logMeal(id: breakfast, at: at(hour: 0))

        try store.createMeal(MealEntryData(id: dinner, createdAt: at(hour: 10), source: .phone))
        // Ad-hoc 80 g: typed 120 kcal, 3 P, 20 C, 2.5 F, 1 fiber.
        try store.addItem(
            .adHoc(id: adHocItem, name: "Stew", quantity: Grams(80), nutrition: nutrition(120, 3, 20, 2.5, fiber: 1)),
            toMeal: dinner
        )
        try store.logMeal(id: dinner, at: at(hour: 10))

        // Day 1 and a day-0 draft: neither belongs in day 0's totals.
        try store.createMeal(MealEntryData(id: nextDay, createdAt: at(day: 1, hour: 1), source: .phone))
        try store.addItem(.catalog(foodID: granola, quantity: Grams(100)), toMeal: nextDay)
        try store.logMeal(id: nextDay, at: at(day: 1, hour: 1))
        try store.createMeal(MealEntryData(id: uid(240), createdAt: at(hour: 11), source: .phone))
        try store.addItem(.catalog(foodID: apple, quantity: Grams(100)), toMeal: uid(240))
    }

    /// Day 0 = 375 + 104 + 120 = 599 kcal; P 15 + 0.5 + 3 = 18.5;
    /// C 45 + 28 + 20 = 93; F 15 + 1 + 2.5 = 18.5; fiber 7.5 + 1 = 8.5.
    let dayZeroTotals = NutritionTotals(summing: [nutrition(599, 18.5, 93, 18.5, fiber: 8.5)])

    func dayZero(_ store: some FreeLunchStore) throws -> NutritionTotals {
        let interval = try #require(utcCalendar.dateInterval(of: .day, for: at(hour: 0)))
        return NutritionTotals.day(containing: at(hour: 0), meals: try store.loggedMeals(in: interval), calendar: utcCalendar)
    }

    func item(_ id: UUID, in meal: UUID, _ store: some FreeLunchStore) throws -> MealItemData {
        let stored = try #require(try store.meal(id: meal))
        return try #require(stored.items.first { $0.id == id })
    }

    @Test("editing a food's macros leaves logged snapshots and day totals bit-identical")
    func editingFoodLeavesHistory() throws {
        let container = try FreeLunchContainer.make(.phone, at: .inMemory)
        let store = SwiftDataStore(container: container)
        try populate(store)

        let granolaBefore = try item(granolaItem, in: breakfast, store)
        let appleBefore = try item(appleItem, in: breakfast, store)
        #expect(sameBits(granolaBefore.nutrition, nutrition(375, 15, 45, 15, fiber: 7.5)))
        #expect(sameBits(appleBefore.nutrition, nutrition(104, 0.5, 28, 1)))
        #expect(try dayZero(store) == dayZeroTotals)

        // Edit both foods' macros (and add fiber to one) after logging.
        var granolaFood = try #require(try store.food(id: granola))
        granolaFood.per100g = nutrition(400, 20, 50, 20, fiber: 9)
        try store.updateFood(granolaFood)
        var appleFood = try #require(try store.food(id: apple))
        appleFood.per100g = nutrition(60, 1, 15, 1, fiber: 2)
        try store.updateFood(appleFood)

        // Read back through a fresh context so the check is on stored rows.
        let reader = SwiftDataStore(container: container)
        #expect(try reader.food(id: granola)?.per100g == nutrition(400, 20, 50, 20, fiber: 9))

        let granolaAfter = try item(granolaItem, in: breakfast, reader)
        let appleAfter = try item(appleItem, in: breakfast, reader)
        #expect(sameBits(granolaAfter.nutrition, granolaBefore.nutrition))
        #expect(sameBits(appleAfter.nutrition, appleBefore.nutrition))
        #expect(granolaAfter.nutrition.fiberG == 7.5)
        #expect(appleAfter.nutrition.fiberG == nil)
        #expect(granolaAfter.quantityGrams.bitPattern == Double(150).bitPattern)

        let after = try dayZero(reader)
        #expect(after == dayZeroTotals)
        #expect(after.kcal.bitPattern == Double(599).bitPattern)
    }

    @Test("an item added after the edit snapshots the new values; old items keep theirs")
    func newItemsUseCurrentValues() throws {
        let store = try makeInMemoryStore()
        try populate(store)
        var granolaFood = try #require(try store.food(id: granola))
        granolaFood.per100g = nutrition(400, 20, 50, 20, fiber: 9)
        try store.updateFood(granolaFood)

        try store.createMeal(MealEntryData(id: uid(250), createdAt: at(day: 2), source: .phone))
        // 150 g at 400/20/50/20/9: 600 kcal, 30 P, 75 C, 30 F, 13.5 fiber.
        let added = try store.addItem(.catalog(foodID: granola, quantity: Grams(150)), toMeal: uid(250))
        #expect(sameBits(added.nutrition, nutrition(600, 30, 75, 30, fiber: 13.5)))
        #expect(sameBits(try item(granolaItem, in: breakfast, store).nutrition, nutrition(375, 15, 45, 15, fiber: 7.5)))
        #expect(try dayZero(store) == dayZeroTotals)
    }

    @Test("updateFood leaves typeahead fields and archive state alone")
    func updateFoodScope() throws {
        let store = try makeInMemoryStore()
        try populate(store)
        try store.archiveFood(id: apple, at: at(day: 3))
        var edited = try #require(try store.food(id: apple))
        edited.name = "Green apple"
        edited.useCount = 99
        edited.archivedAt = nil
        try store.updateFood(edited)

        let stored = try #require(try store.food(id: apple))
        #expect(stored.name == "Green apple")
        // Logged once (breakfast); the day-0 draft does not count.
        #expect(stored.useCount == 1)
        #expect(stored.archivedAt == at(day: 3))
    }
}
