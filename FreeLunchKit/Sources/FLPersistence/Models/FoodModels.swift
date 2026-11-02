// SPDX-License-Identifier: GPL-3.0-or-later
// Catalog models (spec §1 FoodItem, Recipe).
//
// FoodItem's relationships declare `.deny`, but SwiftData does not enforce
// that rule; the real guarantee is that `FreeLunchStore` has no method that
// deletes a FoodItem. Foods are archived, never deleted, once referenced.
//
// `servings` is stored as JSON in `servingsJSON` rather than as a Codable
// array attribute, so the stored form is explicit and keeps ServingDef's
// validated decoding.
import FLCore
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class FoodItem {
        @Attribute(.unique) var id: UUID
        var name: String
        var brand: String?
        // Canonical nutrition per 100 g.
        var kcal: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var fiberG: Double?
        var isLiquid: Bool
        var servingsJSON: Data
        var origin: FoodOrigin
        // Typeahead denormalization, maintained at log time.
        var useCount: Int
        var lastUsedAt: Date?
        var lastPortionGrams: Double?
        var archivedAt: Date?

        @Relationship(deleteRule: .deny, inverse: \MealItem.foodItem)
        var mealItems: [MealItem] = []
        @Relationship(deleteRule: .deny, inverse: \RecipeComponent.foodItem)
        var recipeComponents: [RecipeComponent] = []

        init(
            id: UUID,
            name: String,
            brand: String?,
            kcal: Double,
            proteinG: Double,
            carbsG: Double,
            fatG: Double,
            fiberG: Double?,
            isLiquid: Bool,
            servingsJSON: Data,
            origin: FoodOrigin,
            useCount: Int,
            lastUsedAt: Date?,
            lastPortionGrams: Double?,
            archivedAt: Date?
        ) {
            self.id = id
            self.name = name
            self.brand = brand
            self.kcal = kcal
            self.proteinG = proteinG
            self.carbsG = carbsG
            self.fatG = fatG
            self.fiberG = fiberG
            self.isLiquid = isLiquid
            self.servingsJSON = servingsJSON
            self.origin = origin
            self.useCount = useCount
            self.lastUsedAt = lastUsedAt
            self.lastPortionGrams = lastPortionGrams
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class Recipe {
        @Attribute(.unique) var id: UUID
        var name: String
        /// Canonical grams of the cooked result.
        var yieldGrams: Double
        @Relationship(deleteRule: .cascade, inverse: \RecipeComponent.recipe)
        var components: [RecipeComponent] = []

        init(id: UUID, name: String, yieldGrams: Double) {
            self.id = id
            self.name = name
            self.yieldGrams = yieldGrams
        }
    }

    @Model
    final class RecipeComponent {
        @Attribute(.unique) var id: UUID
        var order: Int
        /// Canonical raw grams.
        var grams: Double
        var foodItem: FoodItem?
        var recipe: Recipe?

        init(id: UUID, order: Int, grams: Double, foodItem: FoodItem?) {
            self.id = id
            self.order = order
            self.grams = grams
            self.foodItem = foodItem
        }
    }
}
