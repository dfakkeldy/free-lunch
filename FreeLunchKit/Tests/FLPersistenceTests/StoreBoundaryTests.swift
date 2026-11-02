// SPDX-License-Identifier: GPL-3.0-or-later
// FLPersistence is a protocol boundary: callers need only the public
// `FreeLunchStore` API and FLCore value types. This file deliberately uses a
// plain `import FLPersistence` (no `@testable`, no SwiftData), so it compiles
// only if the public surface is enough to build a store and run the whole
// round-trip scenario.
import FLCore
import FLPersistence
import Foundation
import Testing

@MainActor
@Suite("FLPersistence protocol boundary")
struct StoreBoundaryTests {
    @Test("the SwiftData store is usable purely as `any FreeLunchStore`")
    func existentialStore() throws {
        let store: any FreeLunchStore = try SwiftDataStore.phone(at: .inMemory)
        try store.createFood(FoodItemData(id: uid(1), name: "Synthetic", per100g: nutrition(100, 4, 12, 3), origin: .custom))
        try store.createMeal(MealEntryData(id: uid(2), createdAt: at(), source: .phone))
        // 50 g at 100/4/12/3: 50 kcal, 2 P, 6 C, 1.5 F.
        let item = try store.addItem(.catalog(foodID: uid(1), quantity: Grams(50)), toMeal: uid(2))
        #expect(sameBits(item.nutrition, nutrition(50, 2, 6, 1.5)))
        let logged = try store.logMeal(id: uid(2), at: at(hour: 1))
        #expect(logged.state == .logged)
        #expect(logged.totals == NutritionTotals(summing: [nutrition(50, 2, 6, 1.5)]))
    }

    @Test("the round-trip scenario runs through the lane protocols alone")
    func scenarioThroughProtocol() throws {
        let store: any FreeLunchStore = try SwiftDataStore.watch(at: .inMemory)
        try populateRoundTripScenario(store)
        #expect(try store.meals().count == 2)
        #expect(try store.shots().count == 1)
    }
}
