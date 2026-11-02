// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — FoodItemData and RecipeData (spec §1 FoodItem, Recipe)
//
// Value-type mirrors of the catalog entities. The `Data` suffix keeps the
// plain names free for the SwiftData models in FLPersistence, which no
// caller outside that module ever sees.
//
// Nutrition is per 100 g, canonical units only (kcal and grams). A portion's
// nutrition is `per100g × grams / 100`, computed field by field as
// `value * grams / 100` (multiply first, then divide), so a test can predict
// the exact Double.
import Foundation

public struct FoodItemData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var brand: String?
    /// Canonical nutrition per 100 g.
    public var per100g: NutritionValues
    /// Display "ml" instead of "g". The stored quantity is still grams.
    public var isLiquid: Bool
    public var servings: [ServingDef]
    public var origin: FoodOrigin
    /// Typeahead denormalization, maintained by the store when a plate is
    /// logged (spec §1).
    public var useCount: Int
    public var lastUsedAt: Date?
    /// Canonical grams of the most recent logged portion. Set through
    /// `Grams`; see `setLastPortion(_:)`.
    public private(set) var lastPortionGrams: Double?
    /// Archived foods are hidden from typeahead but stay resolvable from
    /// history (spec §1: archive, never delete, once referenced).
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        per100g: NutritionValues,
        isLiquid: Bool = false,
        servings: [ServingDef] = [],
        origin: FoodOrigin,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        lastPortion: Grams? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.per100g = per100g
        self.isLiquid = isLiquid
        self.servings = servings
        self.origin = origin
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.lastPortionGrams = lastPortion?.value
        self.archivedAt = archivedAt
    }

    public mutating func setLastPortion(_ portion: Grams?) {
        lastPortionGrams = portion?.value
    }

    /// The nutrition of `quantity` grams of this food.
    public func nutrition(for quantity: Grams) -> NutritionValues {
        per100g.scaled(toGrams: quantity)
    }
}

extension NutritionValues {
    /// Treats `self` as per-100 g values and returns the values for
    /// `quantity` grams: each field is `value * grams / 100`.
    public func scaled(toGrams quantity: Grams) -> NutritionValues {
        let grams = quantity.value
        func scale(_ value: Double) -> Double { value * grams / 100 }
        return NutritionValues(
            kcal: Kilocalories(scale(kcal)),
            protein: Grams(scale(proteinG)),
            carbs: Grams(scale(carbsG)),
            fat: Grams(scale(fatG)),
            fiber: fiberG.map { Grams(scale($0)) }
        )
    }
}

/// One ingredient of a recipe: a catalog food and its raw grams.
public struct RecipeComponentData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var foodID: UUID
    /// Canonical grams of the raw ingredient.
    public private(set) var grams: Double

    public init(id: UUID = UUID(), foodID: UUID, grams: Grams) {
        self.id = id
        self.foodID = foodID
        self.grams = grams.value
    }
}

/// A recipe (spec §1). Cooked yield differs from the raw sum, so the yield
/// is stored and the per-100 g nutrition is computed from it.
public struct RecipeData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// In order; the array order is the component order.
    public var components: [RecipeComponentData]
    /// Canonical grams of the cooked result.
    public private(set) var yieldGrams: Double

    public init(id: UUID = UUID(), name: String, components: [RecipeComponentData], yield: Grams) {
        self.id = id
        self.name = name
        self.components = components
        self.yieldGrams = yield.value
    }

    /// Per-100 g nutrition of the cooked recipe: the sum of each
    /// component's nutrition, times 100, divided by the yield. Nil when a
    /// component's food is missing from `foods` or the yield is zero.
    public func nutritionPer100g(resolving foods: [UUID: FoodItemData]) -> NutritionValues? {
        guard yieldGrams > 0 else { return nil }
        var portions: [NutritionValues] = []
        for component in components {
            guard let food = foods[component.foodID] else { return nil }
            portions.append(food.nutrition(for: Grams(component.grams)))
        }
        let total = NutritionTotals(summing: portions)
        func per100(_ value: Double) -> Double { value * 100 / yieldGrams }
        return NutritionValues(
            kcal: Kilocalories(per100(total.kcal)),
            protein: Grams(per100(total.proteinG)),
            carbs: Grams(per100(total.carbsG)),
            fat: Grams(per100(total.fatG)),
            fiber: total.fiberG.map { Grams(per100($0)) }
        )
    }
}
