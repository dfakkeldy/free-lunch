// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import FLPlate
import Foundation
import Testing

@Suite("Timeline feed") struct TimelineFeedTests {
    @Test func orderAndBounds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: now)! }
        let plans = [PlannedMealData(plannedAt: at(3), name: "Later"), PlannedMealData(plannedAt: at(1), name: "Soon"), PlannedMealData(plannedAt: at(8), name: "Outside")]
        let notes = [JournalEntryData(at: at(-3), text: "Three"), JournalEntryData(at: at(-1), text: "One"), JournalEntryData(at: at(-2), text: "Two")]
        let feed = TimelineFeed.build(now: now, calendar: calendar, meals: [], shots: [], weights: [], effects: [], journal: notes, plannedShots: [], plannedMeals: plans)
        #expect(feed.upcoming.map(\.id) == ["planned-meal-\(plans[1].id)", "planned-meal-\(plans[0].id)"])
        #expect(feed.today.day == calendar.startOfDay(for: now))
        #expect(Array(feed.past.prefix(3)).map(\.day) == [-1, -2, -3].map { calendar.startOfDay(for: at($0)) })
        #expect(feed.past.count == 30)
        #expect(feed.past.prefix(3).map { $0.items.count } == [1, 1, 1])
    }

    @Test func neutralGlyphs() {
        #expect([TimelineGlyph.complete, .markedNotTracked, .empty].map(\.symbol) == ["checkmark.circle", "minus.circle", "circle"])
    }

    @Test func dayHeaderHasNoRedStyle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("FreeLunchPhone/TimelineDayView.swift"), encoding: .utf8)
        let header = source.components(separatedBy: "struct NextDoseRow")[0]
        #expect(!header.lowercased().contains(".red"))
    }
}
