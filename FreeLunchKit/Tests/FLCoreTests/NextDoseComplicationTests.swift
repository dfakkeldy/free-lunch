// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLCore

struct NextDoseComplicationTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Halifax")!
        return result
    }
    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
    }
    private func dose(_ due: Date) -> WatchNextDoseData {
        .init(medicationID: UUID(), medicationName: "Example", doseMg: 1, nextDoseAt: due, intervalDays: 7)
    }

    @Test func timelineTransitionsAcrossDST() {
        let due = date(9, 9)
        let entries = NextDoseTimeline.entries(dueAt: due, now: date(7), calendar: calendar, overdueDays: 2)
        #expect(entries.contains { $0.date == date(9) && $0.status == .dueToday(dueAt: due) })
        #expect(entries.contains { $0.date == due && $0.status == .dueToday(dueAt: due) })
        #expect(entries.contains { $0.date == due.addingTimeInterval(1) && $0.status == .overdue(dueAt: due, daysLate: 0) })
        #expect(entries.contains { $0.date == date(10) && $0.status == .overdue(dueAt: due, daysLate: 1) })
    }

    @Test func localShotAndDigestDeduplicateReloads() throws {
        var state = NextDoseComplicationState(nextDose: dose(date(9)))
        var reloads = 0
        state.shotLogged(at: date(8, 9), calendar: calendar) { reloads += 1 }
        let projection = try #require(state.nextDose)
        #expect(projection.nextDoseAt == date(15, 9))
        state.digestApplied(.init(generatedAt: date(8), recentFoods: [], nextDose: dose(date(9)))) { reloads += 1 }
        #expect(state.nextDose == projection)
        state.digestApplied(.init(generatedAt: date(8, 10), recentFoods: [], nextDose: dose(date(9)))) { reloads += 1 }
        #expect(state.nextDose == projection)
        state.digestApplied(.init(generatedAt: date(8, 10), recentFoods: [], nextDose: projection)) { reloads += 1 }
        #expect(reloads == 1)
        let restored = try JSONDecoder().decode(NextDoseComplicationState.self, from: JSONEncoder().encode(state))
        #expect(restored.nextDose == projection)
    }

    @Test func oldDigestDecodesWithoutInterval() throws {
        let encoded = try JSONEncoder().encode(dose(date(9)))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "intervalDays")
        let decoded = try JSONDecoder().decode(WatchNextDoseData.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.intervalDays == nil)
    }
    @Test func missingIntervalClearsOverdueAndWaitsForPhone() {
        var old = dose(date(7))
        old.intervalDays = nil
        var state = NextDoseComplicationState(nextDose: old)
        var reloads = 0
        state.shotLogged(at: date(8), calendar: calendar) { reloads += 1 }
        #expect(state.nextDose == nil)
        state.digestApplied(.init(generatedAt: date(8, 1), recentFoods: [], nextDose: old)) { reloads += 1 }
        #expect(state.nextDose == nil)
        #expect(reloads == 1)
    }

    @Test func overdueLabelsAndMidnights() {
        #expect(NextDoseComplicationLabel.overdue(days: 0) == "Due today")
        #expect(NextDoseComplicationLabel.overdue(days: 1) == "Due 1 day ago")
        #expect(NextDoseComplicationLabel.overdue(days: 2) == "Due 2 days ago")
        let entries = NextDoseTimeline.entries(dueAt: date(7, 9), now: date(7, 10), calendar: calendar, overdueDays: 3)
        #expect(entries.map(\.date) == [date(7, 10), date(8), date(9), date(10)])
        #expect(entries.last?.status == .overdue(dueAt: date(7, 9), daysLate: 3))
    }

}
