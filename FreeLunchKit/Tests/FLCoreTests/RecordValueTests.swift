// SPDX-License-Identifier: GPL-3.0-or-later
// Pure checks of the plate value types: portion scaling, totals and the
// day filter. Expected values are worked by hand and exactly representable.
import FLCore
import Foundation
import Testing

private func values(_ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double, fiber: Double? = nil) -> NutritionValues {
    NutritionValues(kcal: Kilocalories(kcal), protein: Grams(protein), carbs: Grams(carbs), fat: Grams(fat), fiber: fiber.map { Grams($0) })
}

private let start = Date(timeIntervalSince1970: 1_767_600_000) // 2026-01-05 08:00 UTC

private func item(_ order: Int, _ nutrition: NutritionValues) -> MealItemData {
    MealItemData(order: order, foodID: nil, adHocName: "x", quantity: Grams(1), nutrition: nutrition, provenance: .typed)
}

@Suite("Plate value types")
struct RecordValueTests {
    @Test("a portion is per-100 g × grams ÷ 100, fiber kept optional")
    func portionScaling() {
        let food = FoodItemData(name: "Synthetic", per100g: values(250, 10, 30, 10, fiber: 5), origin: .custom)
        // 40 g: 100 kcal, 4 P, 12 C, 4 F, 2 fiber.
        #expect(food.nutrition(for: Grams(40)) == values(100, 4, 12, 4, fiber: 2))
        let noFiber = FoodItemData(name: "Synthetic", per100g: values(52, 0.25, 14, 0.5), origin: .custom)
        #expect(noFiber.nutrition(for: Grams(200)).fiberG == nil)
    }

    @Test("totals sum snapshots; fiber is nil only when no item has it")
    func totals() {
        let withFiber = NutritionTotals(summing: [values(100, 1, 2, 3, fiber: 1.5), values(50, 0.5, 1, 0.25)])
        #expect(withFiber == NutritionTotals(summing: [values(150, 1.5, 3, 3.25, fiber: 1.5)]))
        #expect(NutritionTotals(summing: [values(10, 0, 0, 0)]).fiberG == nil)
        #expect(NutritionTotals.zero.kcal == 0 && NutritionTotals.zero.fiberG == nil)
    }

    @Test("day totals count logged meals inside the calendar day only")
    func dayTotals() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let inDay = MealEntryData(state: .logged, createdAt: start, loggedAt: start, items: [item(0, values(300, 10, 20, 5))], source: .phone)
        // Logged at 23:59:59 the same UTC day: counts.
        let lateSameDay = MealEntryData(
            state: .logged, createdAt: start, loggedAt: start.addingTimeInterval(16 * 3_600 - 1),
            items: [item(0, values(200, 5, 10, 2)), item(1, values(25, 0, 5, 0))], source: .phone
        )
        // Midnight next day: does not count.
        let nextDay = MealEntryData(state: .logged, createdAt: start, loggedAt: start.addingTimeInterval(16 * 3_600), items: [item(0, values(999, 0, 0, 0))], source: .phone)
        let draft = MealEntryData(state: .draft, createdAt: start, items: [item(0, values(777, 0, 0, 0))], source: .phone)

        let totals = NutritionTotals.day(containing: start, meals: [nextDay, draft, lateSameDay, inDay], calendar: calendar)
        // 300 + 200 + 25 = 525 kcal; 15 P; 35 C; 7 F.
        #expect(totals == NutritionTotals(summing: [values(525, 15, 35, 7)]))
    }

    @Test("recipe nutrition is nil when a component's food is unknown")
    func recipeMissingFood() {
        let recipe = RecipeData(name: "R", components: [RecipeComponentData(foodID: UUID(), grams: Grams(10))], yield: Grams(10))
        #expect(recipe.nutritionPer100g(resolving: [:]) == nil)
    }
}
