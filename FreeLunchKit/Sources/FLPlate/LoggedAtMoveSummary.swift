// SPDX-License-Identifier: GPL-3.0-or-later
// What the logged plate shows after its `loggedAt` is changed (spec §2
// "Log", acceptance #8): the plate moved, and both days' totals as they now
// stand, recomputed from the stored snapshots. Moving never presents the
// post-log sheet; this small readout on the plate is the confirmation.
//
// Locale-independent like the rest of FLPlate's text, so tests can predict
// every character.
import FLCore
import Foundation

public struct LoggedAtMoveSummary: Sendable, Hashable {
    /// One day's logged totals after the move.
    public struct DayLine: Sendable, Hashable {
        public let day: LoggedDay
        public let totals: MacroAmounts

        public init(day: LoggedDay, totals: NutritionTotals) {
            self.day = day
            self.totals = MacroAmounts(totals)
        }

        /// "Yesterday: 650 kcal · P 28 g · C 80 g · F 22 g".
        public var text: String {
            "\(day.name): \(PlateFormat.whole(totals.kcal)) kcal · \(PlateFormat.macroLine(totals))"
        }
    }

    /// The plate that moved.
    public let mealID: UUID
    /// The day the plate left.
    public let previous: DayLine
    /// The day the plate is now in.
    public let current: DayLine

    /// `previousTotals` and `currentTotals` are the two days' logged totals
    /// after the move; the days are named relative to now.
    public init(
        mealID: UUID,
        previousDay: LoggedDay,
        previousTotals: NutritionTotals,
        currentDay: LoggedDay,
        currentTotals: NutritionTotals
    ) {
        self.mealID = mealID
        previous = DayLine(day: previousDay, totals: previousTotals)
        current = DayLine(day: currentDay, totals: currentTotals)
    }

    /// Whether the plate stayed in the same day (only its time changed).
    public var isSameDay: Bool { previous.day == current.day }

    /// "Moved to yesterday", "Moved to Jan 3", or "Time changed".
    public var title: String {
        guard !isSameDay else { return "Time changed" }
        switch current.day {
        case .today: return "Moved to today"
        case .yesterday: return "Moved to yesterday"
        case let .other(date): return "Moved to \(date)"
        }
    }

    /// The day the plate left, then the day it joined; one line when the
    /// plate stayed in its day.
    public var lines: [DayLine] {
        isSameDay ? [current] : [previous, current]
    }
}
