// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §11: the seed's shape, identity and validation. The values-vs-FDC
// golden check for ten staples is in FoodSeedStaplesTests.
import Foundation
import Testing
@testable import FLCore

@Suite("Food catalog seed: identity and validation")
struct FoodCatalogSeedTests {
    func entry(
        _ key: String = "oats",
        name: String = "Oats",
        fdcId: Int = 173_904,
        kcal: Double = 389,
        protein: Double = 16.9,
        carbs: Double = 66.3,
        fat: Double = 6.9,
        fiber: Double? = 10.6,
        servings: [ServingDef] = [],
        since: Int = 1
    ) -> FoodSeedEntry {
        FoodSeedEntry(
            key: key,
            name: name,
            fdcId: fdcId,
            fdcDataType: .srLegacy,
            per100g: NutritionValues(
                kcal: Kilocalories(kcal),
                protein: Grams(protein),
                carbs: Grams(carbs),
                fat: Grams(fat),
                fiber: fiber.map { Grams($0) }
            ),
            isLiquid: false,
            servings: servings,
            since: since
        )
    }

    @Test("derived ids are name-based (v5) UUIDs, pinned so they can never drift")
    func derivedIDsArePinned() {
        // Expected values computed independently with Python's uuid.uuid5 over
        // the same namespace. Changing any of them re-seeds every device.
        #expect(FoodSeedIdentity.namespace.uuidString == "6F1D2C84-3B7A-4E59-9C06-A2D81E5B47F3")
        #expect(FoodSeedIdentity.id(forKey: "chicken-breast-roasted").uuidString == "924F58A1-55A8-5FED-8E79-962D76A60D2B")
        #expect(FoodSeedIdentity.id(forKey: "white-rice-cooked").uuidString == "60C3623D-E5A2-58FA-BBD0-A84F00F4CB07")
        #expect(FoodSeedIdentity.id(forKey: "olive-oil").uuidString == "B90C5A10-1C6D-54F3-B7A8-C46BE9EFD1F3")
        #expect(FoodSeedIdentity.id(forKey: "olive-oil") == FoodSeedIdentity.id(forKey: "olive-oil"))
        #expect(FoodSeedIdentity.id(forKey: "olive-oil") != FoodSeedIdentity.id(forKey: "olive-oil-2"))
    }

    @Test("an entry becomes an unused .seeded catalog row with its derived id")
    func entryMapsToFoodItem() throws {
        let food = entry(servings: [ServingDef(name: "1 cup", grams: Grams(81))]).foodItemData()
        #expect(food.id == FoodSeedIdentity.id(forKey: "oats"))
        #expect(food.origin == .seeded)
        #expect(food.useCount == 0 && food.lastUsedAt == nil && food.lastPortionGrams == nil && food.archivedAt == nil)
        #expect(food.brand == nil)
        #expect(food.servings == [ServingDef(name: "1 cup", grams: Grams(81))])
    }

    @Test("a valid seed decodes from JSON")
    func decodes() throws {
        let json = #"""
        {"seedVersion":2,"foods":[
          {"key":"oats","name":"Oats","fdcId":173904,"dataType":"SR Legacy","kcal":389,"proteinG":16.9,
           "carbsG":66.3,"fatG":6.9,"fiberG":10.6,"isLiquid":false,
           "servings":[{"name":"1 cup","grams":81}],"since":1},
          {"key":"milk","name":"Milk","fdcId":171265,"dataType":"SR Legacy","kcal":61,"proteinG":3.15,
           "carbsG":4.8,"fatG":3.25,"isLiquid":true,"servings":[],"since":2}
        ]}
        """#
        let seed = try FoodCatalogSeed(jsonData: Data(json.utf8))
        #expect(seed.seedVersion == 2)
        #expect(seed.foods.map(\.key) == ["oats", "milk"])
        #expect(seed.foods[1].per100g.fiberG == nil)
        #expect(seed.foods[1].isLiquid)
        #expect(seed.entries(introducedThrough: 1).map(\.key) == ["oats"])
        #expect(seed.entries(introducedThrough: 2).map(\.key) == ["oats", "milk"])
    }

    @Test("a negative value in JSON is rejected, not trapped")
    func negativeJSONValue() {
        let json = #"""
        {"seedVersion":1,"foods":[{"key":"bad","name":"Bad","fdcId":1,"dataType":"SR Legacy","kcal":-5,
        "proteinG":1,"carbsG":1,"fatG":1,"isLiquid":false,"servings":[],"since":1}]}
        """#
        #expect(throws: FoodSeedError.invalidValue(key: "bad")) {
            try FoodCatalogSeed(jsonData: Data(json.utf8))
        }
    }

    @Test("a duplicate key is rejected, which is what keeps bumps additive")
    func duplicateKey() {
        #expect(throws: FoodSeedError.duplicateKey("oats")) {
            try FoodCatalogSeed(seedVersion: 2, foods: [entry(), entry("oats", name: "Oats again", since: 2)])
        }
    }

    @Test("names that fold to the same text are rejected")
    func duplicateName() {
        #expect(throws: FoodSeedError.duplicateName("CAFÉ")) {
            try FoodCatalogSeed(seedVersion: 1, foods: [entry("cafe-1", name: "cafe"), entry("cafe-2", name: "CAFÉ")])
        }
    }

    @Test("bad versions, keys, ids, values, servings and since stamps are rejected")
    func otherValidation() {
        #expect(throws: FoodSeedError.invalidSeedVersion(0)) { try FoodCatalogSeed(seedVersion: 0, foods: []) }
        for key in ["", "Oats", "oat meal", "oats_1"] {
            #expect(throws: FoodSeedError.invalidKey(key)) { try FoodCatalogSeed(seedVersion: 1, foods: [entry(key)]) }
        }
        #expect(throws: FoodSeedError.emptyName(key: "oats")) { try FoodCatalogSeed(seedVersion: 1, foods: [entry(name: "  ")]) }
        #expect(throws: FoodSeedError.invalidFDCID(key: "oats")) { try FoodCatalogSeed(seedVersion: 1, foods: [entry(fdcId: 0)]) }
        #expect(throws: FoodSeedError.invalidSince(key: "oats")) { try FoodCatalogSeed(seedVersion: 1, foods: [entry(since: 2)]) }
        #expect(throws: FoodSeedError.invalidSince(key: "oats")) { try FoodCatalogSeed(seedVersion: 1, foods: [entry(since: 0)]) }
        // Macros that cannot fit in 100 g, fiber above carbohydrate, absurd energy.
        #expect(throws: FoodSeedError.invalidValue(key: "oats")) { try FoodCatalogSeed(seedVersion: 1, foods: [entry(protein: 60, carbs: 60)]) }
        #expect(throws: FoodSeedError.invalidValue(key: "oats")) { try FoodCatalogSeed(seedVersion: 1, foods: [entry(carbs: 5, fiber: 6)]) }
        #expect(throws: FoodSeedError.invalidValue(key: "oats")) { try FoodCatalogSeed(seedVersion: 1, foods: [entry(kcal: 950)]) }
        #expect(throws: FoodSeedError.invalidServing(key: "oats")) {
            try FoodCatalogSeed(seedVersion: 1, foods: [entry(servings: [ServingDef(name: "x", grams: Grams(0))])])
        }
        #expect(throws: FoodSeedError.invalidServing(key: "oats")) {
            try FoodCatalogSeed(seedVersion: 1, foods: [entry(servings: [
                ServingDef(name: "1 cup", grams: Grams(80)), ServingDef(name: "1 cup", grams: Grams(90))
            ])])
        }
    }
}
