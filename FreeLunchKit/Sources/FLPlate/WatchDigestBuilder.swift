// SPDX-License-Identifier: GPL-3.0-or-later
// The phone side of the watch digest (spec §9 root screen, §1 store shape).
//
// Recent foods are §2's empty-query typeahead, taken to the watch cap: the
// same score, the same tie-breaks, archived and never-used foods left out.
// They come from `Typeahead.rows` itself rather than a second sort, so the
// wrist list can never drift from the phone's. The next-dose projection is
// §5's and arrives here already computed; today-remaining is the plate
// screen's `RemainingToday` inputs, carried as plain numbers.
import FLCore
import Foundation

public enum WatchDigestBuilder {
    /// The ranked recent foods, best first, at most
    /// `WatchDigestData.recentFoodCap`. Each row keeps the food's last
    /// portion as the watch's tap-to-log default.
    public static func recentFoods(from foods: [TypeaheadFood], now: Date) -> [RecentFoodSnapshotData] {
        Typeahead.rows(query: "", foods: foods, now: now, foodLimit: WatchDigestData.recentFoodCap)
            .compactMap { row in
                guard case let .food(food, _, prefillGrams) = row else { return nil }
                return RecentFoodSnapshotData(foodID: food.id, name: food.name, lastPortionGrams: prefillGrams)
            }
    }

    /// Today's target and logged totals for the calendar day containing
    /// `now`. A nil target stays nil: "no target adopted", never imputed.
    public static func todayRemaining(
        target: DailyTarget?,
        consumed: MacroAmounts,
        now: Date,
        calendar: Calendar
    ) -> WatchTodayRemainingData {
        WatchTodayRemainingData(
            day: calendar.startOfDay(for: now),
            consumed: WatchMacroValues(consumed),
            target: target.map { WatchMacroValues($0.amounts) }
        )
    }

    public static func digest(
        foods: [TypeaheadFood],
        nextDose: WatchNextDoseData?,
        target: DailyTarget?,
        consumedToday: MacroAmounts,
        now: Date,
        calendar: Calendar
    ) -> WatchDigestData {
        WatchDigestData(
            generatedAt: now,
            recentFoods: recentFoods(from: foods, now: now),
            nextDose: nextDose,
            todayRemaining: todayRemaining(target: target, consumed: consumedToday, now: now, calendar: calendar)
        )
    }
}

extension WatchMacroValues {
    init(_ amounts: MacroAmounts) {
        self.init(kcal: amounts.kcal, proteinG: amounts.proteinG, carbsG: amounts.carbsG, fatG: amounts.fatG)
    }
}
