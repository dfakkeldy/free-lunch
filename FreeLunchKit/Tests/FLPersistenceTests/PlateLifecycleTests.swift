// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §2 plate lifecycle")
struct PlateLifecycleTests {
    private let oats = FoodItemData(
        id: uid(1), name: "Oats", per100g: nutrition(400, 10, 60, 8, fiber: 10), origin: .custom
    )
    private let milk = FoodItemData(
        id: uid(2), name: "Milk", per100g: nutrition(50, 4, 5, 2), origin: .custom
    )

    private func service(_ store: SwiftDataStore, hour: Double = 0) -> PlateLifecycleService {
        PlateLifecycleService(store: store, now: { at(hour: hour) })
    }

    @Test("draft survives file relaunch with a pending AI record")
    func draftPersistence() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }

        do {
            let writer = try SwiftDataStore.phone(at: .file(url))
            let lifecycle = service(writer)
            try writer.createFood(oats)
            try writer.createFood(milk)
            try lifecycle.startDraft(id: uid(10))
            try lifecycle.addCatalogItem(foodID: oats.id, quantity: Grams(50), toMeal: uid(10))
            try lifecycle.addAdHocItem(
                name: "Restaurant guess", quantity: Grams(200), nutrition: nutrition(300, 20, 30, 10), toMeal: uid(10)
            )
            try writer.createAIEstimation(AIEstimationRecordData(
                id: uid(30), createdAt: at(), providerTier: 1, modelID: "synthetic", status: .pending
            ))
            try writer.addItem(MealItemInput(
                kind: .adHoc(name: "AI plate", nutrition: nutrition(100, 5, 10, 2)),
                quantity: Grams(150), provenance: .aiEstimate, aiRecordID: uid(30), confidence: 0.5
            ), toMeal: uid(10))
        }

        let reader = try SwiftDataStore.phone(at: .file(url))
        let lifecycle = service(reader)
        let drafts = try lifecycle.drafts()
        #expect(drafts.count == 1)
        let draft = try #require(drafts.first)
        #expect(draft.id == uid(10))
        #expect(draft.state == .draft)
        #expect(draft.loggedAt == nil)
        #expect(draft.items.count == 3)
        #expect(sameBits(draft.items[0].nutrition, nutrition(200, 5, 30, 4, fiber: 5)))
        #expect(draft.items[0].quantityGrams == 50)
        #expect(draft.items[1].adHocName == "Restaurant guess")
        #expect(draft.items[1].quantityGrams == 200)
        #expect(sameBits(draft.items[1].nutrition, nutrition(300, 20, 30, 10)))
        #expect(draft.items[2].provenance == .aiEstimate)
        #expect(draft.items[2].aiRecordID == uid(30))
        #expect(draft.items[2].quantityGrams == 150)
        #expect(sameBits(draft.items[2].nutrition, nutrition(100, 5, 10, 2)))
        #expect(try reader.aiEstimation(id: uid(30))?.status == .pending)
        #expect(try lifecycle.resumeDraft(id: uid(10)) == draft)
    }

    @Test("multiple drafts are ordered and only drafts resume")
    func multipleDrafts() throws {
        let store = try makeInMemoryStore()
        try service(store, hour: 1).startDraft(id: uid(11))
        try service(store, hour: 2).startDraft(id: uid(12))
        let lifecycle = service(store)

        #expect(try lifecycle.drafts().map(\.id) == [uid(11), uid(12)])
        #expect(throws: FreeLunchStoreError.notFound(uid(99))) { try lifecycle.resumeDraft(id: uid(99)) }
        try lifecycle.log(mealID: uid(11), at: at(hour: 4))
        #expect(throws: FreeLunchStoreError.mealNotDraft(uid(11))) { try lifecycle.resumeDraft(id: uid(11)) }
        #expect(try lifecycle.drafts().map(\.id) == [uid(12)])
    }

    @Test("AI completion never logs a draft")
    func noAutoLog() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store, hour: 4)
        try lifecycle.startDraft(id: uid(20))
        let pending = AIEstimationRecordData(id: uid(31), createdAt: at(), providerTier: 1, modelID: "synthetic", status: .pending)
        try store.createAIEstimation(pending)
        try store.addItem(MealItemInput(
            kind: .adHoc(name: "AI plate", nutrition: nutrition(100, 5, 10, 2)),
            quantity: Grams(150), provenance: .aiEstimate, aiRecordID: uid(31), confidence: 0.5
        ), toMeal: uid(20))
        var completed = pending
        completed.status = .complete
        completed.responseJSON = Data("{}".utf8)
        completed.userCorrections = ["less rice"]
        try store.updateAIEstimation(completed)

        #expect(try store.meal(id: uid(20))?.state == .draft)
        #expect(try store.meal(id: uid(20))?.loggedAt == nil)
        let draftTotals = try lifecycle.dayTotals(containing: at(hour: 4), calendar: utcCalendar)
        #expect(draftTotals.kcal == 0 && draftTotals.proteinG == 0 && draftTotals.carbsG == 0 && draftTotals.fatG == 0 && draftTotals.fiberG == nil)
        #expect(try store.loggedMeals(in: utcCalendar.dateInterval(of: .day, for: at(hour: 4))!).isEmpty)
        #expect(try store.aiEstimation(id: uid(31))?.status == .complete)

        let aiItemID = try #require(try store.meal(id: uid(20))?.items.first?.id)
        try lifecycle.setItemQuantity(Grams(200), itemID: aiItemID)
        try lifecycle.setHunger(3, mealID: uid(20))
        try lifecycle.addAdHocItem(name: "Manual", quantity: Grams(100), nutrition: nutrition(1, 1, 1, 1), toMeal: uid(20))
        #expect(try store.meal(id: uid(20))?.state == .draft)

        let logged = try lifecycle.log(mealID: uid(20))
        #expect(logged.state == .logged && logged.loggedAt == at(hour: 4))
        #expect(throws: FreeLunchStoreError.mealNotDraft(uid(20))) { try lifecycle.log(mealID: uid(20)) }
    }

    @Test("late logging relocates snapshots between calendar days")
    func lateLogging() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        try lifecycle.startDraft(id: uid(40))
        try lifecycle.addAdHocItem(name: "A", quantity: Grams(100), nutrition: nutrition(200, 10, 20, 5), toMeal: uid(40))
        try lifecycle.startDraft(id: uid(41))
        try lifecycle.addAdHocItem(name: "B", quantity: Grams(100), nutrition: nutrition(300, 15, 30, 10), toMeal: uid(41))
        try lifecycle.log(mealID: uid(40), at: at(hour: 4))
        try lifecycle.log(mealID: uid(41), at: at(hour: 5))

        var today = try lifecycle.dayTotals(containing: at(hour: 4), calendar: utcCalendar)
        var yesterday = try lifecycle.dayTotals(containing: at(day: -1, hour: 12), calendar: utcCalendar)
        #expect(today.kcal == 500 && today.proteinG == 25 && today.carbsG == 50 && today.fatG == 15)
        #expect(yesterday.kcal == 0 && yesterday.proteinG == 0 && yesterday.carbsG == 0 && yesterday.fatG == 0)
        try lifecycle.setLoggedAt(at(day: -1, hour: 12), mealID: uid(41))
        today = try lifecycle.dayTotals(containing: at(hour: 4), calendar: utcCalendar)
        yesterday = try lifecycle.dayTotals(containing: at(day: -1, hour: 12), calendar: utcCalendar)
        #expect(today.kcal == 200 && today.proteinG == 10 && today.carbsG == 20 && today.fatG == 5)
        #expect(yesterday.kcal == 300 && yesterday.proteinG == 15 && yesterday.carbsG == 30 && yesterday.fatG == 10)
        #expect(try store.loggedMeals(in: utcCalendar.dateInterval(of: .day, for: at(day: -1, hour: 12))!).map(\.id) == [uid(41)])

        try lifecycle.startDraft(id: uid(42))
        #expect(try lifecycle.log(mealID: uid(42), at: at(day: -1, hour: 12)).loggedAt == at(day: -1, hour: 12))
        try lifecycle.startDraft(id: uid(43))
        #expect(throws: PlateLifecycleError.mealNotLogged(uid(43))) {
            try lifecycle.setLoggedAt(at(day: -1, hour: 12), mealID: uid(43))
        }
    }

    @Test("moving a logged meal reconciles catalog-food typeahead recency")
    func movingLoggedMealReconcilesTypeaheadRecency() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        try store.createFood(oats)

        let mealB = uid(44)
        let yesterdayEvening = at(day: -1, hour: 18)
        try lifecycle.startDraft(id: mealB)
        try lifecycle.addCatalogItem(foodID: oats.id, quantity: Grams(80), toMeal: mealB)
        try lifecycle.log(mealID: mealB, at: yesterdayEvening)

        let mealA = uid(45)
        try lifecycle.startDraft(id: mealA)
        try lifecycle.addCatalogItem(foodID: oats.id, quantity: Grams(50), toMeal: mealA)
        try lifecycle.log(mealID: mealA, at: at(hour: 10))
        #expect(try store.food(id: oats.id)?.lastUsedAt == at(hour: 10))
        #expect(try store.food(id: oats.id)?.lastPortionGrams == 50)

        try lifecycle.setLoggedAt(at(day: -2, hour: 10), mealID: mealA)
        #expect(try store.food(id: oats.id)?.lastUsedAt == yesterdayEvening)
        #expect(try store.food(id: oats.id)?.lastPortionGrams == 80)
    }

    @Test("editing a logged item rescales only its stored snapshot")
    func editLoggedMeal() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        try store.createFood(oats)
        try lifecycle.startDraft(id: uid(60))
        let original = try lifecycle.addCatalogItem(foodID: oats.id, quantity: Grams(50), toMeal: uid(60))
        try lifecycle.log(mealID: uid(60), at: at(hour: 4))
        let updated = try lifecycle.setItemQuantity(Grams(100), itemID: original.id)
        #expect(updated.quantityGrams == 100)
        #expect(sameBits(updated.nutrition, nutrition(400, 10, 60, 8, fiber: 10)))
        #expect(updated.provenance == .typed && updated.order == original.order)
        #expect(try lifecycle.dayTotals(containing: at(hour: 4), calendar: utcCalendar).kcal == 400)
        #expect(throws: PlateLifecycleError.invalidQuantity(original.id)) {
            try lifecycle.setItemQuantity(Grams(0), itemID: original.id)
        }

        var changedOats = oats
        changedOats.per100g = nutrition(999, 1, 1, 1)
        try store.updateFood(changedOats)
        let afterFoodEdit = try #require(try store.meal(id: uid(60))?.items.first)
        #expect(sameBits(afterFoodEdit.nutrition, updated.nutrition))
        #expect(try lifecycle.dayTotals(containing: at(hour: 4), calendar: utcCalendar).kcal == 400)

        let pending = AIEstimationRecordData(id: uid(31), createdAt: at(), providerTier: 1, modelID: "synthetic")
        try store.createAIEstimation(pending)
        let ai = try store.addItem(MealItemInput(
            kind: .adHoc(name: "AI", nutrition: nutrition(10, 1, 1, 1)), quantity: Grams(10),
            provenance: .aiEstimate, aiRecordID: uid(31), confidence: 0.5
        ), toMeal: uid(60))
        let resizedAI = try lifecycle.setItemQuantity(Grams(20), itemID: ai.id)
        #expect(resizedAI.provenance == .aiEstimate && resizedAI.aiRecordID == uid(31))
    }

    @Test("ad-hoc save as food keeps the plate item ad-hoc")
    func adHocSaveAsFood() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        try store.createFood(oats)
        try lifecycle.startDraft(id: uid(70))
        let saved = try lifecycle.addAdHocItem(
            name: "Pasta special", quantity: Grams(150), nutrition: nutrition(300, 15, 30, 6),
            toMeal: uid(70), saveAsFoodID: uid(50)
        )
        #expect(saved.item.adHocName == "Pasta special" && saved.item.foodID == nil)
        #expect(sameBits(saved.item.nutrition, nutrition(300, 15, 30, 6)))
        let food = try #require(saved.food)
        #expect(food.origin == .custom && food.name == "Pasta special" && food.per100g.fiberG == nil)
        #expect(sameBits(food.per100g, nutrition(200, 10, 20, 4)))
        #expect(try store.food(id: uid(50)) == food)
        #expect(try store.foods(includingArchived: false).contains(food))

        let mealBeforeRefusal = try #require(try store.meal(id: uid(70)))
        let itemCount = mealBeforeRefusal.items.count
        #expect(throws: FreeLunchStoreError.duplicateID(uid(1))) {
            try lifecycle.addAdHocItem(name: "Duplicate", quantity: Grams(10), nutrition: nutrition(1, 1, 1, 1), toMeal: uid(70), saveAsFoodID: uid(1))
        }
        #expect(try store.meal(id: uid(70))?.items.count == itemCount)
        #expect(throws: PlateLifecycleError.invalidQuantity(uid(70))) {
            try lifecycle.addAdHocItem(name: "Zero", quantity: Grams(0), nutrition: nutrition(1, 1, 1, 1), toMeal: uid(70), saveAsFoodID: uid(51))
        }
        #expect(try store.food(id: uid(51)) == nil)
        #expect(try lifecycle.addAdHocItem(name: "Only item", quantity: Grams(1), nutrition: nutrition(1, 1, 1, 1), toMeal: uid(70)).food == nil)
    }

    @Test("invalid item quantities are rejected before creating an item or food")
    func invalidItemQuantitiesAreAtomic() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        let mealID = uid(71)
        try store.createFood(oats)
        try lifecycle.startDraft(id: mealID)

        // Grams itself cannot hold negative or non-finite values, so zero is the reachable invalid case.
        for (index, grams) in [0.0].enumerated() {
            #expect(throws: PlateLifecycleError.invalidQuantity(mealID)) {
                try lifecycle.addCatalogItem(foodID: oats.id, quantity: Grams(grams), toMeal: mealID)
            }
            #expect(throws: PlateLifecycleError.invalidQuantity(mealID)) {
                try lifecycle.addAdHocItem(
                    name: "Invalid", quantity: Grams(grams), nutrition: nutrition(1, 1, 1, 1),
                    toMeal: mealID, saveAsFoodID: uid(200 + index)
                )
            }
        }

        #expect(try store.meal(id: mealID)?.items.isEmpty == true)
        #expect(try store.foods(includingArchived: true).map(\.id) == [oats.id])
    }

    @Test("saving an ad-hoc item and catalog food does not leave an orphan on failure")
    func savingAdHocItemAndFoodIsAtomic() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        let mealID = uid(72)
        let item = MealItemInput.adHoc(
            id: uid(73), name: "Existing", quantity: Grams(10), nutrition: nutrition(1, 1, 1, 1)
        )
        let unsavedFood = FoodItemData(
            id: uid(74), name: "Would be orphaned", per100g: nutrition(10, 1, 1, 1), origin: .custom
        )
        try lifecycle.startDraft(id: mealID)
        try store.addItem(item, toMeal: mealID)

        #expect(throws: FreeLunchStoreError.duplicateID(item.id)) {
            try store.addAdHocItemSavingFood(unsavedFood, item: item, toMeal: mealID)
        }
        #expect(try store.food(id: unsavedFood.id) == nil)
        #expect(try store.meal(id: mealID)?.items.count == 1)
    }

    @Test("hunger is optional and constrained to one through five")
    func hunger() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        try lifecycle.startDraft(id: uid(80))
        #expect(try store.meal(id: uid(80))?.hunger == nil)
        for hunger in 1...5 {
            try lifecycle.setHunger(hunger, mealID: uid(80))
            #expect(try store.meal(id: uid(80))?.hunger == hunger)
        }
        try lifecycle.setHunger(nil, mealID: uid(80))
        #expect(try store.meal(id: uid(80))?.hunger == nil)
        try lifecycle.setHunger(3, mealID: uid(80))
        #expect(throws: FreeLunchStoreError.invalidHunger(0)) { try lifecycle.setHunger(0, mealID: uid(80)) }
        #expect(throws: FreeLunchStoreError.invalidHunger(6)) { try lifecycle.setHunger(6, mealID: uid(80)) }
        #expect(try store.meal(id: uid(80))?.hunger == 3)
        try lifecycle.startDraft(id: uid(81))
        try lifecycle.log(mealID: uid(81), at: at(hour: 4))
        #expect(try store.meal(id: uid(81))?.hunger == nil)
    }

    @Test("imported meals refuse late logging and item edits atomically")
    func importedMealIsImmutable() throws {
        let store = try makeInMemoryStore()
        let imported = MealEntryData(
            id: uid(90), state: .logged, createdAt: at(), loggedAt: at(hour: 4),
            items: [MealItemData(id: uid(91), order: 0, foodID: nil, adHocName: "Imported", quantity: Grams(100), nutrition: nutrition(100, 5, 10, 2), provenance: .imported)],
            source: .healthKitImport
        )
        try store.createMeal(imported)
        let before = try StoreGraph(store, aiRecordIDs: [])
        #expect(throws: FreeLunchStoreError.importedRecordImmutable(uid(90))) {
            try store.setLoggedAt(at(day: -1), mealID: uid(90))
        }
        #expect(throws: FreeLunchStoreError.importedRecordImmutable(uid(90))) {
            try store.setItemQuantity(Grams(200), itemID: uid(91))
        }
        #expect(try StoreGraph(store, aiRecordIDs: []) == before)
    }

    @Test("logging a catalog item increments typeahead use count")
    func typeaheadDenormalization() throws {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        try store.createFood(oats)
        try lifecycle.startDraft(id: uid(100))
        try lifecycle.addCatalogItem(foodID: oats.id, quantity: Grams(50), toMeal: uid(100))
        try lifecycle.log(mealID: uid(100), at: at(hour: 4))
        #expect(try store.food(id: oats.id)?.useCount == 1)
    }
}
