// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import FLPlate
import Foundation
import Testing

@Suite("Typeahead ordering")
struct TypeaheadTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func ago(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    var foods: [TypeaheadFood] {
        [
            food(1, "Oatmeal", useCount: 10, lastUsedAt: ago(0), lastPortionGrams: 40),
            food(2, "Banana", useCount: 8, lastUsedAt: ago(30), lastPortionGrams: 118),
            food(3, "Apple", useCount: 3, lastUsedAt: ago(0), lastPortionGrams: 182),
            food(4, "Almonds", useCount: 20, lastUsedAt: ago(90), lastPortionGrams: 28),
            food(5, "Green apple", useCount: 4, lastUsedAt: ago(30)),
            food(6, "Egg", useCount: 5, lastUsedAt: ago(60), lastPortionGrams: 50),
            food(7, "Applesauce"),
            food(8, "Pineapple"),
            food(9, "Granola"),
            food(10, "Orange"),
            food(11, "Rice cake"),
            food(12, "Banana bread", useCount: 99, lastUsedAt: ago(0), isArchived: true)
        ]
    }

    @Test("empty and whitespace queries use only frequent history")
    func emptyAndWhitespaceQueries() {
        let expected = [
            "Oatmeal|frequent",
            "Banana|frequent",
            "Apple|frequent",
            "Almonds|frequent",
            "Green apple|frequent",
            "Egg|frequent",
            "tail:newFood",
            "tail:adHocEntry"
        ]

        #expect(rowLabels(Typeahead.rows(query: "", foods: foods, now: now)) == expected)
        #expect(rowLabels(Typeahead.rows(query: "   ", foods: foods, now: now)) == expected)
    }

    @Test("prefix and substring results preserve their tiers")
    func matchingOrder() {
        #expect(rowLabels(Typeahead.rows(query: "app", foods: foods, now: now)) == [
            "Apple|frequent",
            "Green apple|frequent",
            "Applesauce|prefix",
            "Pineapple|substring",
            "tail:newFood",
            "tail:adHocEntry"
        ])
        #expect(rowLabels(Typeahead.rows(query: "al", foods: foods, now: now)) == [
            "Oatmeal|frequent",
            "Almonds|frequent",
            "tail:newFood",
            "tail:adHocEntry"
        ])
        #expect(rowLabels(Typeahead.rows(query: "an", foods: foods, now: now)) == [
            "Banana|frequent",
            "Granola|substring",
            "Orange|substring",
            "tail:newFood",
            "tail:adHocEntry"
        ])
    }

    @Test("never-used prefix matches precede substring matches")
    func zeroScoreTierOrder() {
        let chickpeas = food(22, "Chickpeas")
        let peanutButter = food(23, "Peanut butter")

        #expect(rowLabels(Typeahead.rows(query: "pea", foods: [chickpeas, peanutButter], now: now)) == [
            "Peanut butter|prefix",
            "Chickpeas|substring",
            "tail:newFood",
            "tail:adHocEntry"
        ])
    }

    @Test("matching is case and diacritic insensitive, and tails are unconditional")
    func normalizedMatchingAndTails() {
        let appExpected = [
            "Apple|frequent",
            "Green apple|frequent",
            "Applesauce|prefix",
            "Pineapple|substring",
            "tail:newFood",
            "tail:adHocEntry"
        ]
        #expect(rowLabels(Typeahead.rows(query: "APP", foods: foods, now: now)) == appExpected)
        #expect(rowLabels(Typeahead.rows(query: "zzz", foods: foods, now: now)) == [
            "tail:newFood",
            "tail:adHocEntry"
        ])

        let café = food(20, "Café au lait")
        let skyr = food(21, "Skyr", brand: "Arla")
        #expect(rowLabels(Typeahead.rows(query: "cafe", foods: [café], now: now)) == [
            "Café au lait|prefix",
            "tail:newFood",
            "tail:adHocEntry"
        ])
        #expect(rowLabels(Typeahead.rows(query: "arl", foods: [skyr], now: now)) == [
            "Skyr|substring",
            "tail:newFood",
            "tail:adHocEntry"
        ])
    }

    @Test("food rows retain the latest portion as their prefill")
    func prefills() {
        let appRows = Typeahead.rows(query: "app", foods: foods, now: now)
        let emptyRows = Typeahead.rows(query: "", foods: foods, now: now)

        #expect(prefill(for: "Apple", in: appRows) == 182)
        #expect(prefill(for: "Green apple", in: appRows) == nil)
        #expect(prefill(for: "Oatmeal", in: emptyRows) == 40)
    }

    @Test("food limits do not remove tail actions")
    func foodLimits() {
        #expect(rowLabels(Typeahead.rows(query: "", foods: foods, now: now, foodLimit: 2)) == [
            "Oatmeal|frequent",
            "Banana|frequent",
            "tail:newFood",
            "tail:adHocEntry"
        ])
        #expect(rowLabels(Typeahead.rows(query: "", foods: foods, now: now, foodLimit: 0)) == [
            "tail:newFood",
            "tail:adHocEntry"
        ])
    }

    @Test("result order is independent of input order")
    func determinism() {
        let reversed = Array(foods.reversed())
        let rotated = Array(foods.dropFirst(3)) + Array(foods.prefix(3))

        for query in ["", "app"] {
            let expected = Typeahead.rows(query: query, foods: foods, now: now)
            #expect(Typeahead.rows(query: query, foods: reversed, now: now) == expected)
            #expect(Typeahead.rows(query: query, foods: rotated, now: now) == expected)
        }
    }

    @Test("frequent ties use count, recency, name, then identifier")
    func frequentTieBreaks() {
        let alpha = food(30, "Alpha", useCount: 2, lastUsedAt: now)
        let beta = food(31, "Beta", useCount: 2, lastUsedAt: now)
        let a = food(32, "A", useCount: 4, lastUsedAt: ago(30))
        let b = food(33, "B", useCount: 2, lastUsedAt: now)

        #expect(rowLabels(Typeahead.rows(query: "", foods: [beta, alpha], now: now)) == [
            "Alpha|frequent",
            "Beta|frequent",
            "tail:newFood",
            "tail:adHocEntry"
        ])
        #expect(rowLabels(Typeahead.rows(query: "", foods: [b, a], now: now)) == [
            "A|frequent",
            "B|frequent",
            "tail:newFood",
            "tail:adHocEntry"
        ])
    }

    @Test("the watch digest is the empty-query order with last portions (spec §9)")
    func watchDigestOrder() {
        let digest = WatchDigestBuilder.recentFoods(from: foods, now: now)

        #expect(digest.map(\.name) == ["Oatmeal", "Banana", "Apple", "Almonds", "Green apple", "Egg"])
        #expect(digest.map(\.lastPortionGrams) == [40, 118, 182, 28, nil, 50])
        #expect(digest.map(\.foodID) == foodIDs(Typeahead.rows(query: "", foods: foods, now: now)))
        #expect(WatchDigestBuilder.recentFoods(from: foods.reversed(), now: now) == digest)
    }

    @Test("the watch digest caps at 200 foods, keeping the best ranked")
    func watchDigestCap() {
        let many = foods + (100...349).map { number in
            food(number, "Food \(number)", useCount: number % 7 + 1, lastUsedAt: ago(Double(number % 45)))
        }
        let ranked = foodIDs(Typeahead.rows(query: "", foods: many, now: now, foodLimit: many.count))
        let digest = WatchDigestBuilder.recentFoods(from: many, now: now)

        #expect(ranked.count == 256)
        #expect(digest.count == WatchDigestData.recentFoodCap)
        #expect(digest.map(\.foodID) == Array(ranked.prefix(200)))
        #expect(!digest.contains { $0.name == "Banana bread" })
    }

    @Test("scores follow the thirty day half-life")
    func scores() {
        #expect(abs(Typeahead.score(useCount: 10, lastUsedAt: ago(0), now: now) - 10) < 1e-9)
        #expect(abs(Typeahead.score(useCount: 8, lastUsedAt: ago(30), now: now) - 4) < 1e-9)
        #expect(abs(Typeahead.score(useCount: 20, lastUsedAt: ago(90), now: now) - 2.5) < 1e-9)
        #expect(abs(Typeahead.score(useCount: 5, lastUsedAt: ago(60), now: now) - 1.25) < 1e-9)
        #expect(Typeahead.score(useCount: 0, lastUsedAt: ago(0), now: now) == 0)
        #expect(Typeahead.score(useCount: 3, lastUsedAt: nil, now: now) == 0)
        #expect(abs(Typeahead.score(useCount: 3, lastUsedAt: now.addingTimeInterval(5 * 86_400), now: now) - 3) < 1e-9)
    }

    // Spec §11 acceptance #2: the §2 ordering fixture extended with the
    // seed. Every bundled seeded food joins the fixture's foods as a
    // never-used row, so each existing expectation is re-checked with a
    // catalog of a few hundred extra foods in it.
    @Test("seeded foods rank below frequently used foods from day one")
    func seededFoodsRankBelowFrequent() throws {
        let seed = try FoodCatalogSeed.loadBundled()
        let seeded = seed.foods.map { TypeaheadFood(id: $0.id, name: $0.name) }
        let seededIDs = Set(seeded.map(\.id))
        #expect(seeded.count > 250)

        // The empty query shows tier (1) alone, so a never-used seed is invisible.
        #expect(Typeahead.rows(query: "", foods: foods + seeded, now: now)
            == Typeahead.rows(query: "", foods: foods, now: now))

        for query in ["app", "al", "an", "pea"] {
            let baseline = Typeahead.rows(query: query, foods: foods, now: now)
            let baselineFrequent = baseline.filter(isFrequentRow)
            let rows = Typeahead.rows(query: query, foods: foods + seeded, now: now)

            // The fixture's frequent foods keep their exact order, at the top.
            #expect(Array(rows.prefix(baselineFrequent.count)) == baselineFrequent)
            // A seeded food only ever appears after the frequent rows, in the
            // prefix tier when its name starts with the query, else in the
            // substring tier.
            for (index, row) in rows.enumerated() {
                if case let .food(food, tier, _) = row, seededIDs.contains(food.id) {
                    #expect(index >= baselineFrequent.count)
                    let folded = food.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    #expect(tier == (folded.hasPrefix(query) ? .prefix : .substring))
                }
            }
            // The tail actions are still last and still unconditional.
            #expect(Array(rows.suffix(2)) == [.tail(.newFood), .tail(.adHocEntry)])
        }

        // With the seed present, "app" still lists the fixture's frequent
        // foods first and then reaches seeded matches.
        let appRows = Typeahead.rows(query: "app", foods: foods + seeded, now: now)
        #expect(rowLabels(appRows).prefix(2) == ["Apple|frequent", "Green apple|frequent"])
        #expect(appRows.contains { row in
            if case let .food(food, _, _) = row { return seededIDs.contains(food.id) }
            return false
        })
    }

    @Test("a seeded food the user has logged ranks by the same blend as any other food")
    func usedSeededFoodIsJustAFood() throws {
        let seed = try FoodCatalogSeed.loadBundled()
        let seeded = try #require(seed.foods.first)
        let used = TypeaheadFood(id: seeded.id, name: seeded.name, useCount: 2, lastUsedAt: ago(0), lastPortionGrams: 100)
        let others = seed.foods.dropFirst().map { TypeaheadFood(id: $0.id, name: $0.name) }

        let rows = Typeahead.rows(query: "", foods: foods + others + [used], now: now)

        // Score 2 (two uses, today): above Egg (1.25), below Apple (3) and Oatmeal (10).
        let order = rows.compactMap { row -> String? in
            if case let .food(food, _, _) = row { return food.name }
            return nil
        }
        let usedIndex = try #require(order.firstIndex(of: seeded.name))
        #expect(order.firstIndex(of: "Oatmeal")! < usedIndex)   // score 10
        #expect(order.firstIndex(of: "Apple")! < usedIndex)     // score 3
        #expect(usedIndex < order.firstIndex(of: "Egg")!)       // score 1.25
    }

    private func isFrequentRow(_ row: TypeaheadRow) -> Bool {
        if case let .food(_, tier, _) = row { return tier == .frequent }
        return false
    }

    private func food(
        _ number: Int,
        _ name: String,
        brand: String? = nil,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        lastPortionGrams: Double? = nil,
        isArchived: Bool = false
    ) -> TypeaheadFood {
        let identifier = String(format: "00000000-0000-0000-0000-%012d", number)
        return TypeaheadFood(
            id: UUID(uuidString: identifier)!,
            name: name,
            brand: brand,
            useCount: useCount,
            lastUsedAt: lastUsedAt,
            lastPortionGrams: lastPortionGrams,
            isArchived: isArchived
        )
    }

    private func rowLabels(_ rows: [TypeaheadRow]) -> [String] {
        rows.map { row in
            switch row {
            case let .food(food, tier, _):
                return "\(food.name)|\(tierLabel(tier))"
            case let .tail(action):
                return "tail:\(tailLabel(action))"
            }
        }
    }

    private func foodIDs(_ rows: [TypeaheadRow]) -> [UUID] {
        rows.compactMap { row in
            guard case let .food(food, _, _) = row else { return nil }
            return food.id
        }
    }

    private func prefill(for name: String, in rows: [TypeaheadRow]) -> Double? {
        for row in rows {
            if case let .food(food, _, prefillGrams) = row, food.name == name {
                return prefillGrams
            }
        }
        return nil
    }

    private func tierLabel(_ tier: TypeaheadTier) -> String {
        switch tier {
        case .frequent: "frequent"
        case .prefix: "prefix"
        case .substring: "substring"
        }
    }

    private func tailLabel(_ action: TypeaheadTailAction) -> String {
        switch action {
        case .newFood: "newFood"
        case .adHocEntry: "adHocEntry"
        }
    }
}
