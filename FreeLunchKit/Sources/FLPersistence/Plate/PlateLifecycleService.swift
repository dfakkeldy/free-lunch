// SPDX-License-Identifier: GPL-3.0-or-later
// The deliberate user-facing plate lifecycle. Creating or editing a plate is
// separate from logging it: only `log` changes a draft into a logged meal.
import FLCore
import Foundation

@MainActor
public final class PlateLifecycleService {
    private let store: any PlateLifecycleStore
    private let now: @Sendable () -> Date

    public init(store: any PlateLifecycleStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    @discardableResult
    public func startDraft(id: UUID = UUID(), source: MealSource = .phone) throws -> MealEntryData {
        let meal = MealEntryData(id: id, createdAt: now(), source: source)
        try store.createMeal(meal)
        return meal
    }

    public func drafts() throws -> [MealEntryData] {
        try store.meals()
            .filter { $0.state == .draft }
            .sorted(by: mealOrder)
    }

    public func resumeDraft(id: UUID) throws -> MealEntryData {
        guard let meal = try store.meal(id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        guard meal.state == .draft else {
            throw FreeLunchStoreError.mealNotDraft(id)
        }
        return meal
    }

    /// Adds a catalog item. `provenance` says how the grams were obtained
    /// (spec §2 "Weighing flows": a scale reading is `.scaleWeighed`); the
    /// default keeps plain typed entry `.typed`.
    @discardableResult
    public func addCatalogItem(
        foodID: UUID,
        quantity: Grams,
        provenance: ItemProvenance = .typed,
        toMeal mealID: UUID
    ) throws -> MealItemData {
        try validateQuantity(quantity, mealID: mealID)
        return try store.addItem(.catalog(foodID: foodID, quantity: quantity, provenance: provenance), toMeal: mealID)
    }

    /// Adds an ad-hoc item, optionally saving it as a custom food. As with
    /// catalog items, `provenance` defaults to `.typed`.
    @discardableResult
    public func addAdHocItem(
        name: String,
        quantity: Grams,
        nutrition: NutritionValues,
        provenance: ItemProvenance = .typed,
        toMeal mealID: UUID,
        saveAsFoodID: UUID? = nil
    ) throws -> (item: MealItemData, food: FoodItemData?) {
        try validateQuantity(quantity, mealID: mealID)
        if let saveAsFoodID {
            let grams = quantity.value
            try preflightEditableMeal(mealID)
            guard try store.food(id: saveAsFoodID) == nil else {
                throw FreeLunchStoreError.duplicateID(saveAsFoodID)
            }
            let food = FoodItemData(
                id: saveAsFoodID,
                name: name,
                per100g: nutritionPer100g(nutrition, quantityGrams: grams),
                origin: .custom
            )
            let item = try store.addAdHocItemSavingFood(
                food,
                item: .adHoc(name: name, quantity: quantity, nutrition: nutrition, provenance: provenance),
                toMeal: mealID
            )
            return (item, food)
        }

        let item = try store.addItem(
            .adHoc(name: name, quantity: quantity, nutrition: nutrition, provenance: provenance),
            toMeal: mealID
        )
        return (item, nil)
    }

    @discardableResult
    public func setItemQuantity(_ quantity: Grams, itemID: UUID) throws -> MealItemData {
        try store.setItemQuantity(quantity, itemID: itemID)
    }

    public func setHunger(_ hunger: Int?, mealID: UUID) throws {
        try store.setHunger(hunger, mealID: mealID)
    }

    @discardableResult
    public func log(mealID: UUID, at: Date? = nil) throws -> MealEntryData {
        try store.logMeal(id: mealID, at: at ?? now())
    }

    @discardableResult
    public func setLoggedAt(_ date: Date, mealID: UUID) throws -> MealEntryData {
        try store.setLoggedAt(date, mealID: mealID)
    }

    public func dayTotals(containing day: Date, calendar: Calendar) throws -> NutritionTotals {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return .zero }
        let meals = try store.loggedMeals(in: interval)
        return NutritionTotals.day(containing: day, meals: meals, calendar: calendar)
    }

    private func preflightEditableMeal(_ id: UUID) throws {
        guard let meal = try store.meal(id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        guard meal.source != .healthKitImport else {
            throw FreeLunchStoreError.importedRecordImmutable(id)
        }
    }

    private func validateQuantity(_ quantity: Grams, mealID: UUID) throws {
        let grams = quantity.value
        guard grams > 0, grams.isFinite else {
            throw PlateLifecycleError.invalidQuantity(mealID)
        }
    }

    private func nutritionPer100g(_ nutrition: NutritionValues, quantityGrams: Double) -> NutritionValues {
        func per100(_ value: Double) -> Double { value * 100 / quantityGrams }
        return NutritionValues(
            kcal: Kilocalories(per100(nutrition.kcal)),
            protein: Grams(per100(nutrition.proteinG)),
            carbs: Grams(per100(nutrition.carbsG)),
            fat: Grams(per100(nutrition.fatG)),
            fiber: nutrition.fiberG.map { Grams(per100($0)) }
        )
    }

    private func mealOrder(_ lhs: MealEntryData, _ rhs: MealEntryData) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
