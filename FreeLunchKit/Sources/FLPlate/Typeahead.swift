// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct TypeaheadFood: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let brand: String?
    public let useCount: Int
    public let lastUsedAt: Date?
    public let lastPortionGrams: Double?
    public let isArchived: Bool

    public init(
        id: UUID,
        name: String,
        brand: String? = nil,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        lastPortionGrams: Double? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.lastPortionGrams = lastPortionGrams
        self.isArchived = isArchived
    }
}

public enum TypeaheadTier: Sendable, Hashable {
    case frequent
    case prefix
    case substring
}

public enum TypeaheadTailAction: Sendable, Hashable {
    case newFood
    case adHocEntry
}

public enum TypeaheadRow: Sendable, Hashable {
    case food(TypeaheadFood, tier: TypeaheadTier, prefillGrams: Double?)
    case tail(TypeaheadTailAction)
}

public enum Typeahead: Sendable {
    public static let halfLifeDays: Double = 30
    public static let defaultFoodLimit = 8

    private static let secondsPerDay: Double = 86_400

    public static func score(useCount: Int, lastUsedAt: Date?, now: Date) -> Double {
        guard useCount > 0, let lastUsedAt else { return 0 }

        let daysSince = max(0, now.timeIntervalSince(lastUsedAt)) / secondsPerDay
        return Double(useCount) * pow(0.5, daysSince / halfLifeDays)
    }

    /// Returns typeahead rows; a brand-only match is always in the substring tier, even when the brand starts with the query.
    public static func rows(
        query: String,
        foods: [TypeaheadFood],
        now: Date,
        foodLimit: Int = defaultFoodLimit
    ) -> [TypeaheadRow] {
        let limit = max(0, foodLimit)
        let availableFoods = foods.filter { !$0.isArchived }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let foodRows: [TypeaheadRow]
        if trimmedQuery.isEmpty {
            foodRows = availableFoods
                .map { RankedFood(food: $0, score: score(useCount: $0.useCount, lastUsedAt: $0.lastUsedAt, now: now)) }
                .filter { $0.score > 0 }
                .sorted(by: frequentOrder)
                .prefix(limit)
                .map { foodRow($0, tier: .frequent) }
        } else {
            let foldedQuery = fold(trimmedQuery)
            let candidates = availableFoods.compactMap { food -> Match? in
                let rankedFood = RankedFood(
                    food: food,
                    score: score(useCount: food.useCount, lastUsedAt: food.lastUsedAt, now: now)
                )
                let isPrefix = rankedFood.foldedName.hasPrefix(foldedQuery)
                let isSubstring = !isPrefix && (
                    rankedFood.foldedName.contains(foldedQuery) ||
                    food.brand.map { fold($0).contains(foldedQuery) } == true
                )

                guard isPrefix || isSubstring else { return nil }
                return Match(
                    rankedFood: rankedFood,
                    isPrefix: isPrefix
                )
            }

            let frequent = candidates
                .filter { $0.rankedFood.score > 0 }
                .map(\.rankedFood)
                .sorted(by: frequentOrder)

            let prefix = candidates
                .filter { $0.isPrefix && $0.rankedFood.score == 0 }
                .map(\.rankedFood)
                .sorted(by: zeroScoreOrder)

            let substring = candidates
                .filter { !$0.isPrefix && $0.rankedFood.score == 0 }
                .map(\.rankedFood)
                .sorted(by: zeroScoreOrder)

            foodRows = (
                frequent.map { foodRow($0, tier: .frequent) } +
                prefix.map { foodRow($0, tier: .prefix) } +
                substring.map { foodRow($0, tier: .substring) }
            )
            .prefix(limit)
            .map { $0 }
        }

        return foodRows + [.tail(.newFood), .tail(.adHocEntry)]
    }

    private struct RankedFood {
        let food: TypeaheadFood
        let score: Double
        let foldedName: String

        init(food: TypeaheadFood, score: Double) {
            self.food = food
            self.score = score
            foldedName = Typeahead.fold(food.name)
        }
    }

    private struct Match {
        let rankedFood: RankedFood
        let isPrefix: Bool
    }

    private static func foodRow(_ rankedFood: RankedFood, tier: TypeaheadTier) -> TypeaheadRow {
        .food(
            rankedFood.food,
            tier: tier,
            prefillGrams: rankedFood.food.lastPortionGrams
        )
    }

    private static func frequentOrder(_ lhs: RankedFood, _ rhs: RankedFood) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.food.useCount != rhs.food.useCount { return lhs.food.useCount > rhs.food.useCount }

        switch (lhs.food.lastUsedAt, rhs.food.lastUsedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if lhs.foldedName != rhs.foldedName { return lhs.foldedName < rhs.foldedName }
        return lhs.food.id.uuidString < rhs.food.id.uuidString
    }

    private static func zeroScoreOrder(_ lhs: RankedFood, _ rhs: RankedFood) -> Bool {
        if lhs.foldedName != rhs.foldedName { return lhs.foldedName < rhs.foldedName }
        return lhs.food.id.uuidString < rhs.food.id.uuidString
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
