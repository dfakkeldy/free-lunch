// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — NutritionTotals: sums of MealItem snapshots.
//
// Totals are always recomputed from the logged MealItem snapshots (spec §1:
// the snapshot is the record), never from the FoodItem catalog, so editing a
// food can never move a past day's total.
//
// Summation is left to right in the order given. Fiber is optional per item:
// the total is the sum of the items that carry fiber, and nil only when no
// item does.
import Foundation

public struct NutritionTotals: Sendable, Hashable {
    public let kcal: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double
    public let fiberG: Double?

    public static let zero = NutritionTotals(summing: [])

    public init(summing values: [NutritionValues]) {
        var kcal = 0.0
        var protein = 0.0
        var carbs = 0.0
        var fat = 0.0
        var fiber: Double?
        for value in values {
            kcal += value.kcal
            protein += value.proteinG
            carbs += value.carbsG
            fat += value.fatG
            if let itemFiber = value.fiberG {
                fiber = (fiber ?? 0) + itemFiber
            }
        }
        self.kcal = kcal
        self.proteinG = protein
        self.carbsG = carbs
        self.fatG = fat
        self.fiberG = fiber
    }

    /// Totals of the items' snapshots, in item order.
    public init(items: [MealItemData]) {
        self.init(summing: items.sorted(by: MealItemData.displayOrder).map(\.nutrition))
    }

    /// The day's totals: every *logged* meal whose `loggedAt` falls in the
    /// calendar day containing `day`, meals in `loggedAt` order (ties by id),
    /// items in item order. Drafts never count.
    public static func day(
        containing day: Date,
        meals: [MealEntryData],
        calendar: Calendar
    ) -> NutritionTotals {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return .zero }
        let counted = meals
            .filter { meal in
                guard meal.state == .logged, let loggedAt = meal.loggedAt else { return false }
                return loggedAt >= interval.start && loggedAt < interval.end
            }
            .sorted { lhs, rhs in
                if lhs.loggedAt != rhs.loggedAt { return lhs.loggedAt! < rhs.loggedAt! }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let values = counted.flatMap { meal in
            meal.items.sorted(by: MealItemData.displayOrder).map(\.nutrition)
        }
        return NutritionTotals(summing: values)
    }
}
