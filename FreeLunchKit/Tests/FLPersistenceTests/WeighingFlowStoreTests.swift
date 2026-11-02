// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 "Weighing flows" at the store: add-then-weigh and a scale session
// both reach the service as a catalog item with grams and `.scaleWeighed`,
// and the stored items differ only in quantity. The FLPlate side (which
// provenance each flow picks, and that a refused reading never writes) is
// covered in FLPlateTests/WeighingFlowsTests.
import FLCore
import FLFixtures
import Foundation
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §2 weighing flows at the store")
struct WeighingFlowStoreTests {
    private let oats = FoodItemData(
        id: uid(1), name: "Oats", per100g: nutrition(400, 10, 60, 8, fiber: 10), origin: .custom
    )

    private func service(_ store: SwiftDataStore) -> PlateLifecycleService {
        PlateLifecycleService(store: store, now: { at() })
    }

    /// The item with its id and position blanked, so two items compare on
    /// everything they record.
    private func withoutIdentity(_ item: MealItemData) -> MealItemData {
        MealItemData(
            id: uid(0),
            order: 0,
            foodID: item.foodID,
            adHocName: item.adHocName,
            quantity: Grams(item.quantityGrams),
            nutrition: item.nutrition,
            provenance: item.provenance,
            aiRecordID: item.aiRecordID,
            confidence: item.confidence
        )
    }

    @Test("an add-then-weigh item and a scale-session item differ only in id and order")
    func bothFlowsStoreIdenticalItems() throws {
        let store = try makeInMemoryStore()
        try store.createFood(oats)
        let lifecycle = service(store)
        try lifecycle.startDraft(id: uid(10))

        // Add-then-weigh: 162.5 typed into the quantity step's grams field.
        let typedReading = try lifecycle.addCatalogItem(
            foodID: oats.id, quantity: Grams(162.5), provenance: .scaleWeighed, toMeal: uid(10)
        )
        // Weigh-as-you-go: cumulative 250 → 412.5 on the same plate.
        let sessionItem = try lifecycle.addCatalogItem(
            foodID: oats.id, quantity: Grams(162.5), provenance: .scaleWeighed, toMeal: uid(10)
        )

        let meal = try #require(try store.meal(id: uid(10)))
        let stored = meal.items.sorted(by: MealItemData.displayOrder)
        #expect(stored.count == 2)
        #expect(stored.map(\.id) == [typedReading.id, sessionItem.id])

        for item in stored {
            #expect(item.foodID == oats.id)
            #expect(item.adHocName == nil)
            #expect(item.quantityGrams == 162.5)
            #expect(item.provenance == .scaleWeighed)
            #expect(item.aiRecordID == nil)
            #expect(item.confidence == nil)
            // 162.5 g of 400/10/60/8/fiber 10 per 100 g.
            #expect(sameBits(item.nutrition, nutrition(650, 16.25, 97.5, 13, fiber: 16.25)))
        }

        #expect(withoutIdentity(stored[0]) == withoutIdentity(stored[1]))
    }

    @Test("the cumulative fixture lands as exact scale-weighed items and survives relaunch")
    func cumulativeFixtureThroughTheService() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }

        // The grams a cumulative session hands the service for the fixture
        // readings 250, 412.5, (400 refused), 475, 537.25.
        let sessionGrams = WeighingFlowFixtures.cumulative.compactMap(\.expectedGrams)
        #expect(sessionGrams == [250, 162.5, 62.5, 62.25])

        do {
            let writer = try SwiftDataStore.phone(at: .file(url))
            try writer.createFood(oats)
            let lifecycle = service(writer)
            try lifecycle.startDraft(id: uid(20))
            for grams in sessionGrams {
                try lifecycle.addCatalogItem(
                    foodID: oats.id, quantity: Grams(grams), provenance: .scaleWeighed, toMeal: uid(20)
                )
            }
        }

        let reader = try SwiftDataStore.phone(at: .file(url))
        let meal = try #require(try reader.meal(id: uid(20)))
        let items = meal.items.sorted(by: MealItemData.displayOrder)
        #expect(items.map(\.quantityGrams) == [250, 162.5, 62.5, 62.25])
        #expect(items.allSatisfy { $0.provenance == .scaleWeighed })
        #expect(items.allSatisfy { $0.foodID == oats.id && $0.adHocName == nil })

        // Per-100 g 400/10/60/8/fiber 10, worked by hand.
        let expected = [
            nutrition(1000, 25, 150, 20, fiber: 25),
            nutrition(650, 16.25, 97.5, 13, fiber: 16.25),
            nutrition(250, 6.25, 37.5, 5, fiber: 6.25),
            nutrition(249, 6.225, 37.35, 4.98, fiber: 6.225)
        ]
        #expect(items.count == expected.count)
        for (item, value) in zip(items, expected) {
            #expect(sameBits(item.nutrition, value))
        }
        // 1000 + 650 + 250 + 249.
        #expect(meal.totals.kcal == 2149)
    }

    @Test("callers that pass no provenance still store typed items")
    func defaultsStayTyped() throws {
        let store = try makeInMemoryStore()
        try store.createFood(oats)
        let lifecycle = service(store)
        try lifecycle.startDraft(id: uid(30))

        let catalog = try lifecycle.addCatalogItem(foodID: oats.id, quantity: Grams(50), toMeal: uid(30))
        let adHoc = try lifecycle.addAdHocItem(
            name: "Restaurant guess", quantity: Grams(200), nutrition: nutrition(300, 20, 30, 10), toMeal: uid(30)
        )
        let saved = try lifecycle.addAdHocItem(
            name: "House soup", quantity: Grams(300), nutrition: nutrition(150, 6, 18, 6),
            toMeal: uid(30), saveAsFoodID: uid(31)
        )

        #expect(catalog.provenance == .typed)
        #expect(adHoc.item.provenance == .typed)
        #expect(saved.item.provenance == .typed)
        let stored = try #require(try store.meal(id: uid(30))).items
        #expect(stored.count == 3)
        #expect(stored.allSatisfy { $0.provenance == .typed })
    }

    @Test("an explicit provenance reaches both ad-hoc paths")
    func adHocTakesProvenance() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        try lifecycle.startDraft(id: uid(40))

        let plain = try lifecycle.addAdHocItem(
            name: "Weighed stew", quantity: Grams(310), nutrition: nutrition(400, 30, 20, 22),
            provenance: .scaleWeighed, toMeal: uid(40)
        )
        let saved = try lifecycle.addAdHocItem(
            name: "Weighed curry", quantity: Grams(250), nutrition: nutrition(500, 25, 40, 25),
            provenance: .scaleWeighed, toMeal: uid(40), saveAsFoodID: uid(41)
        )

        #expect(plain.item.provenance == .scaleWeighed)
        #expect(saved.item.provenance == .scaleWeighed)
        #expect(saved.food?.origin == .custom)
        let stored = try #require(try store.meal(id: uid(40))).items
        #expect(stored.map(\.provenance) == [.scaleWeighed, .scaleWeighed])
    }
}
