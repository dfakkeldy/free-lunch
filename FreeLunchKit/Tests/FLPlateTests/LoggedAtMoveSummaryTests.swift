// SPDX-License-Identifier: GPL-3.0-or-later
// The readout a logged plate shows after its time changes (spec §2 "Log",
// acceptance #8): both days' totals after the move, named relative to now.
//
// Expected text worked out by hand. The app's UI test uses the first case:
// yesterday held a synthetic 400 kcal / P 20 / C 50 / F 12 plate, and a
// 250 / 8 / 30 / 10 plate moves there from today, so today falls to 0 and
// yesterday rises to 400 + 250 = 650, P 28, C 80, F 22.
import FLCore
import FLPlate
import Foundation
import Testing

@Suite("Late logging: the move readout on a logged plate (spec §2 acceptance #8)")
struct LoggedAtMoveSummaryTests {
    @Test("moved from today to yesterday: both days, the day it left first")
    func todayToYesterday() {
        let summary = LoggedAtMoveSummary(
            mealID: PlateFixture.id(1),
            previousDay: .today,
            previousTotals: PlateFixture.totals(0, 0, 0, 0),
            currentDay: .yesterday,
            currentTotals: PlateFixture.totals(650, 28, 80, 22)
        )

        #expect(!summary.isSameDay)
        #expect(summary.title == "Moved to yesterday")
        #expect(summary.lines.map(\.text) == [
            "Today: 0 kcal · P 0 g · C 0 g · F 0 g",
            "Yesterday: 650 kcal · P 28 g · C 80 g · F 22 g"
        ])
        #expect(summary.previous.text == "Today: 0 kcal · P 0 g · C 0 g · F 0 g")
        #expect(summary.current.text == "Yesterday: 650 kcal · P 28 g · C 80 g · F 22 g")
    }

    @Test("moved to an older day: the date names it; back to today reads 'today'")
    func olderDayAndBack() {
        let older = LoggedAtMoveSummary(
            mealID: PlateFixture.id(2),
            previousDay: .yesterday,
            previousTotals: PlateFixture.totals(400, 20, 50, 12),
            currentDay: .other("Jan 3"),
            currentTotals: PlateFixture.totals(250.4, 8.5, 29.5, 10)
        )
        #expect(older.title == "Moved to Jan 3")
        // 250.4 rounds to 250; 8.5 and 29.5 round half away from zero.
        #expect(older.lines.map(\.text) == [
            "Yesterday: 400 kcal · P 20 g · C 50 g · F 12 g",
            "Jan 3: 250 kcal · P 9 g · C 30 g · F 10 g"
        ])

        let back = LoggedAtMoveSummary(
            mealID: PlateFixture.id(2),
            previousDay: .other("Jan 3"),
            previousTotals: PlateFixture.totals(0, 0, 0, 0),
            currentDay: .today,
            currentTotals: PlateFixture.totals(250, 8, 30, 10)
        )
        #expect(back.title == "Moved to today")
    }

    @Test("a change within the same day shows that day once")
    func sameDay() {
        let summary = LoggedAtMoveSummary(
            mealID: PlateFixture.id(3),
            previousDay: .today,
            previousTotals: PlateFixture.totals(500, 25, 50, 15),
            currentDay: .today,
            currentTotals: PlateFixture.totals(500, 25, 50, 15)
        )
        #expect(summary.isSameDay)
        #expect(summary.title == "Time changed")
        #expect(summary.lines.map(\.text) == ["Today: 500 kcal · P 25 g · C 50 g · F 15 g"])
    }
}
