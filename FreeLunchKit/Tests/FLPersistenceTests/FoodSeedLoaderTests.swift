// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §11 acceptance #1: the seed loads idempotently; an additive bump adds
// without touching user-edited rows; editing a seeded food forks it to
// `.custom` with the seeded original archived. The 10-staples FDC check lives
// in FLCoreTests (FoodCatalogSeedTests). Every user edit here is synthetic.
import FLCore
import Foundation
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §11 acceptance #1: seed loader and fork-on-edit")
struct FoodSeedLoaderTests {
    func entry(_ key: String, _ name: String, kcal: Double = 100, since: Int = 1, servings: [ServingDef] = []) -> FoodSeedEntry {
        FoodSeedEntry(
            key: key,
            name: name,
            fdcId: 100_000 + key.count,
            fdcDataType: .srLegacy,
            per100g: nutrition(kcal, 10, 5, 3, fiber: 1),
            isLiquid: false,
            servings: servings,
            since: since
        )
    }

    func seed(version: Int = 1, _ entries: [FoodSeedEntry]) throws -> FoodCatalogSeed {
        try FoodCatalogSeed(seedVersion: version, foods: entries)
    }

    var v1: [FoodSeedEntry] {
        [
            entry("alpha", "Alpha", servings: [ServingDef(name: "1 cup", grams: Grams(120))]),
            entry("beta", "Beta"),
            entry("gamma", "Gamma")
        ]
    }

    @Test("a first load inserts every entry as an unused, unarchived .seeded food with its derived id")
    func firstLoad() throws {
        let store = try makeInMemoryStore()
        let seed = try seed(v1)

        #expect(try FoodSeedLoader.apply(seed, to: store) == 3)

        let foods = try store.foods(includingArchived: true)
        #expect(foods.count == 3)
        #expect(foods.allSatisfy { $0.origin == .seeded && $0.useCount == 0 && $0.lastUsedAt == nil && $0.archivedAt == nil })
        #expect(Set(foods.map(\.id)) == Set(seed.foods.map(\.id)))
        let alpha = try #require(try store.food(id: FoodSeedIdentity.id(forKey: "alpha")))
        #expect(alpha.name == "Alpha")
        #expect(alpha.per100g == nutrition(100, 10, 5, 3, fiber: 1))
        #expect(alpha.servings == [ServingDef(name: "1 cup", grams: Grams(120))])
    }

    @Test("loading twice inserts nothing and leaves every row as it was")
    func idempotent() throws {
        let store = try makeInMemoryStore()
        let seed = try seed(v1)
        try FoodSeedLoader.apply(seed, to: store)
        let before = try store.foods(includingArchived: true)

        #expect(try FoodSeedLoader.apply(seed, to: store) == 0)
        #expect(try store.foods(includingArchived: true) == before)
    }

    @Test("an additive bump inserts only the new keys and leaves user-edited and archived rows alone")
    func additiveBump() throws {
        let store = try makeInMemoryStore()
        try FoodSeedLoader.apply(seed(v1), to: store)

        let alpha = try #require(try store.food(id: FoodSeedIdentity.id(forKey: "alpha")))
        var edit = alpha
        edit.name = "My alpha"
        edit.per100g = nutrition(250, 12, 30, 8, fiber: 2)
        let fork = try store.editFood(edit, forkID: uid(900), at: at(day: 1))
        try store.archiveFood(id: FoodSeedIdentity.id(forKey: "beta"), at: at(day: 2))
        let userFood = FoodItemData(id: uid(901), name: "Mine", per100g: nutrition(50, 1, 1, 1), origin: .custom)
        try store.createFood(userFood)
        let before = try store.foods(includingArchived: true)

        // v2 adds two keys. It also re-lists the v1 keys unchanged, as the
        // real file does; a changed value for a shipped key must not land.
        let changedAlpha = entry("alpha", "Alpha (renamed upstream)", kcal: 500)
        let v2 = try seed(version: 2, [changedAlpha] + v1.dropFirst() + [
            entry("delta", "Delta", since: 2),
            entry("epsilon", "Epsilon", since: 2)
        ])

        #expect(try FoodSeedLoader.apply(v2, to: store) == 2)

        let after = try store.foods(includingArchived: true)
        #expect(after.count == before.count + 2)
        for row in before { #expect(after.contains(row)) }
        #expect(try store.food(id: fork.id) == fork)
        // The archived seeded rows were not resurrected.
        #expect(try store.food(id: alpha.id)?.archivedAt == at(day: 1))
        #expect(try store.food(id: FoodSeedIdentity.id(forKey: "beta"))?.archivedAt == at(day: 2))
        #expect(try store.foods(includingArchived: false).map(\.name).sorted() ==
            ["Delta", "Epsilon", "Gamma", "Mine", "My alpha"])
    }

    @Test("editing a seeded food forks it: a .custom copy with the edits, the original archived and unchanged")
    func editForks() throws {
        let store = try makeInMemoryStore()
        try FoodSeedLoader.apply(seed(v1), to: store)
        let id = FoodSeedIdentity.id(forKey: "alpha")

        var edit = try #require(try store.food(id: id))
        edit.name = "Alpha, my way"
        edit.brand = "Home"
        edit.per100g = nutrition(180, 11, 20, 6, fiber: 3)
        edit.isLiquid = true
        edit.servings = [ServingDef(name: "1 bowl", grams: Grams(250))]

        let fork = try store.editFood(edit, forkID: uid(700), at: at(day: 5))

        #expect(fork.id == uid(700))
        #expect(fork.origin == .custom)
        #expect(fork.archivedAt == nil)
        #expect(fork.name == "Alpha, my way" && fork.brand == "Home" && fork.isLiquid)
        #expect(sameBits(fork.per100g, nutrition(180, 11, 20, 6, fiber: 3)))
        #expect(fork.servings == [ServingDef(name: "1 bowl", grams: Grams(250))])
        #expect(try store.food(id: uid(700)) == fork)

        let original = try #require(try store.food(id: id))
        #expect(original.origin == .seeded)
        #expect(original.name == "Alpha")
        #expect(original.per100g == nutrition(100, 10, 5, 3, fiber: 1))
        #expect(original.archivedAt == at(day: 5))
        #expect(try store.foods(includingArchived: false).map(\.id).contains(id) == false)
    }

    @Test("a fork keeps the original's typeahead history so it keeps its rank")
    func forkCarriesUsage() throws {
        let container = try FreeLunchContainer.make(.phone, at: .inMemory)
        let store = SwiftDataStore(container: container)
        try FoodSeedLoader.apply(seed(v1), to: store)
        let id = FoodSeedIdentity.id(forKey: "alpha")

        // Log it twice so the store maintains useCount, lastUsedAt and lastPortionGrams.
        for (index, grams) in [(0, 60.0), (1, 85.0)] {
            let meal = uid(500 + index)
            try store.createMeal(MealEntryData(id: meal, createdAt: at(day: Double(index)), source: .phone))
            try store.addItem(.catalog(id: uid(510 + index), foodID: id, quantity: Grams(grams)), toMeal: meal)
            try store.logMeal(id: meal, at: at(day: Double(index)))
        }
        let used = try #require(try store.food(id: id))
        #expect(used.useCount == 2)

        var edit = used
        edit.name = "Alpha, edited"
        let fork = try store.editFood(edit, forkID: uid(701), at: at(day: 9))

        #expect(fork.useCount == 2)
        #expect(fork.lastUsedAt == used.lastUsedAt)
        #expect(fork.lastPortionGrams == 85)
        // History keeps resolving through the archived original.
        #expect(try store.food(id: id)?.useCount == 2)
    }

    @Test("an edit that changes nothing creates no fork")
    func unchangedEditIsANoOp() throws {
        let store = try makeInMemoryStore()
        try FoodSeedLoader.apply(seed(v1), to: store)
        let id = FoodSeedIdentity.id(forKey: "beta")
        let stored = try #require(try store.food(id: id))
        let before = try store.foods(includingArchived: true)

        #expect(try store.editFood(stored, forkID: uid(702), at: at(day: 1)) == stored)
        #expect(try store.foods(includingArchived: true) == before)
    }

    @Test("editing a non-seeded food updates it in place")
    func customEditsInPlace() throws {
        let store = try makeInMemoryStore()
        let custom = FoodItemData(id: uid(800), name: "Soup", per100g: nutrition(40, 2, 5, 1), origin: .custom)
        try store.createFood(custom)

        var edit = custom
        edit.name = "Better soup"
        edit.per100g = nutrition(45, 3, 5, 1)
        let result = try store.editFood(edit, forkID: uid(801), at: at(day: 1))

        #expect(result.id == custom.id && result.name == "Better soup" && result.origin == .custom)
        #expect(try store.foods(includingArchived: true).count == 1)
        #expect(try store.food(id: custom.id)?.archivedAt == nil)
    }

    @Test("editFood refuses an unknown food or an existing fork id, and changes nothing")
    func editRefusals() throws {
        let store = try makeInMemoryStore()
        try FoodSeedLoader.apply(seed(v1), to: store)
        let id = FoodSeedIdentity.id(forKey: "alpha")
        var edit = try #require(try store.food(id: id))
        edit.name = "Changed"
        let before = try store.foods(includingArchived: true)

        #expect(throws: FreeLunchStoreError.notFound(uid(999))) {
            try store.editFood(FoodItemData(id: uid(999), name: "Ghost", per100g: nutrition(1, 0, 0, 0), origin: .custom), forkID: uid(703), at: at())
        }
        #expect(throws: FreeLunchStoreError.duplicateID(FoodSeedIdentity.id(forKey: "beta"))) {
            try store.editFood(edit, forkID: FoodSeedIdentity.id(forKey: "beta"), at: at())
        }
        #expect(try store.foods(includingArchived: true) == before)
    }

    @Test("createFoods is all or nothing")
    func createFoodsAtomic() throws {
        let store = try makeInMemoryStore()
        let existing = FoodItemData(id: uid(1), name: "Existing", per100g: nutrition(1, 0, 0, 0), origin: .custom)
        try store.createFood(existing)

        #expect(throws: FreeLunchStoreError.duplicateID(uid(1))) {
            try store.createFoods([
                FoodItemData(id: uid(2), name: "New", per100g: nutrition(1, 0, 0, 0), origin: .custom),
                FoodItemData(id: uid(1), name: "Clash", per100g: nutrition(1, 0, 0, 0), origin: .custom)
            ])
        }
        #expect(throws: FreeLunchStoreError.duplicateID(uid(3))) {
            try store.createFoods([
                FoodItemData(id: uid(3), name: "Twin", per100g: nutrition(1, 0, 0, 0), origin: .custom),
                FoodItemData(id: uid(3), name: "Twin", per100g: nutrition(1, 0, 0, 0), origin: .custom)
            ])
        }
        #expect(try store.foods(includingArchived: true) == [existing])
    }

    @Test("the bundled seed loads, is idempotent, and survives a cold reopen of the store file")
    func bundledSeedColdReopen() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let seed = try FoodCatalogSeed.loadBundled()

        let first = try SwiftDataStore.phone(at: .file(url))
        #expect(try FoodSeedLoader.applyBundled(to: first).foods.count == seed.foods.count)
        let id = try #require(seed.foods.first).id
        var edit = try #require(try first.food(id: id))
        edit.name = "Edited " + edit.name
        let fork = try first.editFood(edit, forkID: uid(950), at: at(day: 1))

        let reopened = try SwiftDataStore.phone(at: .file(url))
        #expect(try reopened.foods(includingArchived: true).count == seed.foods.count + 1)
        #expect(try FoodSeedLoader.apply(seed, to: reopened) == 0)
        #expect(try reopened.food(id: fork.id) == fork)
        #expect(try reopened.food(id: id)?.origin == .seeded)
        #expect(try reopened.food(id: id)?.archivedAt == at(day: 1))
    }
}
