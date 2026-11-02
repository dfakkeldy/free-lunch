// SPDX-License-Identifier: GPL-3.0-or-later
// Late logging on the phone (spec §2 "Log", acceptance #8): the post-log
// sheet's headings follow the day the plate was logged into, and the
// Log-earlier sheet's quick "yesterday" lands in the previous calendar day.
//
// Expected instants were worked out by hand and checked with a throwaway
// script outside the repo (Python zoneinfo), not read from the code:
// - 1_767_600_000 = 2026-01-05 08:00 UTC.
// - 1_767_578_400 = 2026-01-05 02:00 UTC = 2026-01-04 22:00 AST (Halifax).
// - 1_767_567_600 = 2026-01-04 23:00 UTC = 2026-01-04 19:00 AST.
// - 1_772_982_000 = 2026-03-08 12:00 ADT (daylight time began 02:00 that
//   day); 1_772_899_200 = 2026-03-07 12:00 AST, 23 hours earlier.
import FLCore
import FLPlate
import Foundation
import Testing

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private let utc = calendar("UTC")
private let halifax = calendar("America/Halifax")
/// 2026-01-05 08:00 UTC.
private let now = Date(timeIntervalSince1970: 1_767_600_000)

private func utcHour(day: Double, hour: Double) -> Date {
    // Midnight 2026-01-05 UTC is 1_767_571_200.
    Date(timeIntervalSince1970: 1_767_571_200 + day * 86_400 + hour * 3_600)
}

@Suite("Late logging: the day a plate lands in (spec §2 acceptance #8)")
struct LoggedDayTests {
    @Test("same calendar day as now is today, from midnight on")
    func today() {
        #expect(LoggedDay(loggedAt: utcHour(day: 0, hour: 0), now: now, calendar: utc) == .today)
        #expect(LoggedDay(loggedAt: now, now: now, calendar: utc) == .today)
    }

    @Test("the previous calendar day is yesterday, midnight to 23:59:59")
    func yesterday() {
        #expect(LoggedDay(loggedAt: utcHour(day: -1, hour: 0), now: now, calendar: utc) == .yesterday)
        #expect(LoggedDay(loggedAt: utcHour(day: -1, hour: 12), now: now, calendar: utc) == .yesterday)
        #expect(LoggedDay(loggedAt: utcHour(day: 0, hour: 0).addingTimeInterval(-1), now: now, calendar: utc) == .yesterday)
    }

    @Test("older days carry their short date; another year adds the year")
    func olderDays() {
        #expect(LoggedDay(loggedAt: utcHour(day: -1, hour: 0).addingTimeInterval(-1), now: now, calendar: utc) == .other("Jan 3"))
        #expect(LoggedDay(loggedAt: utcHour(day: -5, hour: 9), now: now, calendar: utc) == .other("Dec 31, 2025"))
    }

    @Test("day boundaries follow the calendar's time zone")
    func timeZone() {
        let lateEvening = Date(timeIntervalSince1970: 1_767_578_400) // Jan 4, 22:00 AST
        let earlierThatEvening = Date(timeIntervalSince1970: 1_767_567_600) // Jan 4, 19:00 AST
        #expect(LoggedDay(loggedAt: earlierThatEvening, now: lateEvening, calendar: halifax) == .today)
        // The same two instants straddle midnight in UTC.
        #expect(LoggedDay(loggedAt: earlierThatEvening, now: lateEvening, calendar: utc) == .yesterday)
    }

    @Test("names and headings for each kind of day")
    func text() {
        #expect(LoggedDay.today.name == "Today")
        #expect(LoggedDay.yesterday.name == "Yesterday")
        #expect(LoggedDay.other("Jan 3").name == "Jan 3")

        #expect(LoggedDay.today.remainingTitle == "Remaining today")
        #expect(LoggedDay.yesterday.remainingTitle == "Remaining yesterday")
        #expect(LoggedDay.other("Jan 3").remainingTitle == "Remaining on Jan 3")

        #expect(LoggedDay.today.totalsTitle == "Today's totals")
        #expect(LoggedDay.yesterday.totalsTitle == "Yesterday's totals")
        #expect(LoggedDay.other("Jan 3").totalsTitle == "Totals for Jan 3")

        #expect(LoggedDay.yesterday.countsTowardText == "Counts toward yesterday")
        #expect(LoggedDay.other("Jan 3").countsTowardText == "Counts toward Jan 3")
    }
}

@Suite("Late logging: the post-log sheet follows the logged day")
struct LateLoggedPostLogSummaryTests {
    @Test("a plate logged to yesterday: yesterday's headings over yesterday's numbers")
    func yesterdaySnapshot() {
        // Yesterday held 1500 kcal P 90 C 170 F 50 with this plate; against
        // 2000 / 150 / 260 / floor 40 that leaves 500, 60, 90 and a met floor.
        let summary = PostLogSummary(
            dayTotals: PlateFixture.dayAfter,
            target: PlateFixture.target,
            day: LoggedDay(loggedAt: utcHour(day: -1, hour: 13), now: now, calendar: utc)
        )

        #expect(summary.day == .yesterday)
        #expect(summary.snapshot == """
        Remaining yesterday
          500 kcal left of 2000 kcal
          Protein 60 g left of 150 g
          Carbs 90 g left of 260 g
          Fat floor of 40 g met
        Yesterday's totals
          1500 kcal
          P 90 g · C 170 g · F 50 g
        """)
        #expect(summary.sections.map(\.kind) == [.remaining, .dailyTotals])
    }

    @Test("an older day is named by its date; no target stays explicit")
    func olderDayWithoutTarget() {
        let summary = PostLogSummary(
            dayTotals: PlateFixture.totals(250, 8, 30, 10),
            target: nil,
            day: LoggedDay(loggedAt: utcHour(day: -2, hour: 20), now: now, calendar: utc)
        )

        #expect(summary.snapshot == """
        Remaining on Jan 3
          No target adopted
        Totals for Jan 3
          250 kcal
          P 8 g · C 30 g · F 10 g
        """)
    }

    @Test("the default is still today, so the unchanged Log path reads as before")
    func defaultIsToday() {
        let summary = PostLogSummary(dayTotals: PlateFixture.dayAfter, target: nil)
        #expect(summary.day == .today)
        #expect(summary.sections.map(\.title) == ["Remaining today", "Today's totals"])
    }
}

@Suite("Late logging: quick choices in the Log-earlier sheet")
struct LateLogTimeTests {
    @Test("same time yesterday is one calendar day back")
    func sameTimeYesterday() {
        #expect(LateLogTime.sameTimeYesterday(now: now, calendar: utc) == Date(timeIntervalSince1970: 1_767_513_600))
        #expect(LoggedDay(loggedAt: LateLogTime.sameTimeYesterday(now: now, calendar: utc), now: now, calendar: utc) == .yesterday)
    }

    @Test("across the spring-forward change it is 23 hours back, still yesterday at the same clock time")
    func sameTimeYesterdayAcrossDST() {
        let noonAfterChange = Date(timeIntervalSince1970: 1_772_982_000) // 2026-03-08 12:00 ADT
        let yesterdayNoon = LateLogTime.sameTimeYesterday(now: noonAfterChange, calendar: halifax)
        #expect(yesterdayNoon == Date(timeIntervalSince1970: 1_772_899_200)) // 2026-03-07 12:00 AST
        #expect(noonAfterChange.timeIntervalSince(yesterdayNoon) == 23 * 3_600)
        #expect(LoggedDay(loggedAt: yesterdayNoon, now: noonAfterChange, calendar: halifax) == .yesterday)
    }

    @Test("the picker starts at the plate's loggedAt, else now, and never after now")
    func initialSelection() {
        let earlier = now.addingTimeInterval(-3_600)
        #expect(LateLogTime.initialSelection(current: nil, now: now) == now)
        #expect(LateLogTime.initialSelection(current: earlier, now: now) == earlier)
        #expect(LateLogTime.initialSelection(current: now.addingTimeInterval(60), now: now) == now)
    }
}
