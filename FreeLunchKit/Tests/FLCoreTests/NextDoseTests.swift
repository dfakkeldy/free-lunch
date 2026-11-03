// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5 Next dose: the projection follows the latest actual shot, counted in
// calendar days, and the overdue state begins strictly after the projected
// instant.
//
// January fixtures sit clear of a DST change in Halifax; the March and
// November cases straddle one on purpose.
import FLCore
import Foundation
import Testing

@Suite("Next-dose projection")
struct NextDoseTests {
    /// The injected calendar for every fixture, in Halifax.
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Halifax")!
        return calendar
    }

    /// UTC has no DST, so seven calendar days there are always 168 hours.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A Halifax wall-clock time: `at(2026, 1, 5)` is 09:00 local.
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9, _ mi: Int = 0, _ s: Int = 0) -> Date {
        makeDate(in: cal, y, mo, d, h, mi, s)
    }

    /// A UTC wall-clock time, for the time-zone test.
    private func utcAt(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9, _ mi: Int = 0, _ s: Int = 0) -> Date {
        makeDate(in: utc, y, mo, d, h, mi, s)
    }

    /// `NextDose.status` at `now`, with the suite's calendar and profile.
    private func status(
        _ shots: [ShotEventData],
        _ medication: MedicationProfileData?,
        at now: Date
    ) -> NextDoseStatus? {
        NextDose.status(shots: shots, activeProfile: medication, now: now, calendar: cal)
    }

    /// A fixed UUID, so a fixture is the same shot on every run.
    private func uuid(_ n: Int) -> UUID {
        let suffix = String(format: "%012d", n)
        guard let uuid = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") else {
            preconditionFailure("fixture UUID \(n) is not valid")
        }
        return uuid
    }

    /// A semaglutide profile: the flat 7-day interval unless a test says
    /// otherwise.
    private func profile(
        _ n: Int,
        intervalDays: Int = MedicationProfileData.defaultIntervalDays,
        archivedAt: Date? = nil
    ) -> MedicationProfileData {
        MedicationProfileData(
            id: uuid(900 + n),
            name: "Semaglutide \(n)",
            halfLifeHours: KnownMedication.semaglutide.halfLifeHours,
            tmaxHours: KnownMedication.semaglutide.tmaxHours,
            intervalDays: intervalDays,
            archivedAt: archivedAt
        )
    }

    private func shot(_ n: Int, on day: Date, of medication: MedicationProfileData) -> ShotEventData {
        ShotEventData(id: uuid(n), takenAt: day, dose: Milligrams(0.5), medicationID: medication.id)
    }

    // MARK: projection

    @Test("a regular weekly history projects seven days after the latest shot")
    func regularSchedule() {
        let p = profile(1)
        let shots = [shot(1, on: at(2026, 1, 5), of: p), shot(2, on: at(2026, 1, 12), of: p)]
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal) == at(2026, 1, 19))
    }

    @Test("a shot two days late moves the whole future schedule")
    func lateShotShiftsSchedule() {
        let p = profile(1)
        let shots = [shot(1, on: at(2026, 1, 5), of: p), shot(2, on: at(2026, 1, 14), of: p)]
        let next = NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal)
        #expect(next == at(2026, 1, 21))
        #expect(next != at(2026, 1, 19))
    }

    @Test("a takenAt edited after logging counts at its edited time")
    func editedTakenAtCounts() {
        let p = profile(1)
        var second = shot(2, on: at(2026, 1, 12), of: p)
        second.takenAt = at(2026, 1, 12, 21, 30)
        let shots = [shot(1, on: at(2026, 1, 5), of: p), second]
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal) == at(2026, 1, 19, 21, 30))
    }

    @Test("editing an older shot past the latest makes it the latest")
    func editedOlderShotBecomesLatest() {
        let p = profile(1)
        var first = shot(1, on: at(2026, 1, 5), of: p)
        let second = shot(2, on: at(2026, 1, 12), of: p)
        first.takenAt = at(2026, 1, 13, 8)

        for shots in [[first, second], [second, first]] {
            let next = NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal)
            #expect(next == at(2026, 1, 20, 8))
        }
    }

    @Test("a ten-day interval projects ten calendar days out")
    func customInterval() {
        let p = profile(1, intervalDays: 10)
        let shots = [shot(1, on: at(2026, 1, 5), of: p)]
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal) == at(2026, 1, 15))
    }

    @Test("two shots at the same instant project one deterministic date")
    func ties() {
        let p = profile(1)
        let a = shot(1, on: at(2026, 1, 5), of: p)
        let b = shot(2, on: at(2026, 1, 5), of: p)
        let forwards = NextDose.nextDoseAt(shots: [a, b], activeProfile: p, calendar: cal)
        let backwards = NextDose.nextDoseAt(shots: [b, a], activeProfile: p, calendar: cal)
        #expect(forwards == at(2026, 1, 12))
        #expect(forwards == backwards)
    }

    // MARK: nothing to project

    @Test("no shots means no projection")
    func noShots() {
        let p = profile(1)
        #expect(NextDose.nextDoseAt(shots: [], activeProfile: p, calendar: cal) == nil)
        #expect(status([], p, at: at(2026, 1, 12)) == nil)
    }

    @Test("no active profile means no projection, whatever the history holds")
    func noActiveProfile() {
        let p = profile(1)
        let shots = [shot(1, on: at(2026, 1, 5), of: p)]
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: nil, calendar: cal) == nil)
        #expect(status(shots, nil, at: at(2026, 1, 12)) == nil)
    }

    @Test("an archived active profile has no projection")
    func archivedProfile() {
        let p = profile(1, archivedAt: at(2026, 1, 2))
        let shots = [shot(1, on: at(2026, 1, 5), of: p)]
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal) == nil)
        #expect(status(shots, p, at: at(2026, 1, 12)) == nil)
    }

    @Test("a zero interval has no projection")
    func zeroInterval() {
        let p = profile(1, intervalDays: 0)
        let shots = [shot(1, on: at(2026, 1, 5), of: p)]
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal) == nil)
    }

    @Test("each profile projects from its own shots only")
    func multipleMedications() {
        let p = profile(1)
        let q = profile(2)
        let shots = [shot(1, on: at(2026, 1, 5), of: p), shot(2, on: at(2026, 1, 10), of: q)]
        // A Q shot never moves P's projection.
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal) == at(2026, 1, 12))
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: q, calendar: cal) == at(2026, 1, 17))
    }

    // MARK: the calm overdue state

    @Test("overdue begins one second after the projected instant")
    func overdueBoundary() {
        let p = profile(1)
        let shots = [shot(1, on: at(2026, 1, 5), of: p)]
        let dueAt = at(2026, 1, 12)

        #expect(status(shots, p, at: dueAt.addingTimeInterval(-1))
            == NextDoseStatus.dueToday(dueAt: dueAt))
        #expect(status(shots, p, at: dueAt)
            == NextDoseStatus.dueToday(dueAt: dueAt))
        #expect(status(shots, p, at: dueAt.addingTimeInterval(1))
            == NextDoseStatus.overdue(dueAt: dueAt, daysLate: 0))
    }

    @Test("the last second of the previous day is upcoming, not due today")
    func upcomingVersusDueToday() {
        let p = profile(1)
        let shots = [shot(1, on: at(2026, 1, 5), of: p)]
        let dueAt = at(2026, 1, 12)

        let lastSecond = status(shots, p, at: at(2026, 1, 11, 23, 59, 59))
        #expect(lastSecond == NextDoseStatus.upcoming(dueAt: dueAt))
        let midnight = status(shots, p, at: at(2026, 1, 12, 0, 0, 0))
        #expect(midnight == NextDoseStatus.dueToday(dueAt: dueAt))
    }

    @Test("days late counts calendar days from the due date to today")
    func daysLateCountsCalendarDays() {
        let p = profile(1)
        let shots = [shot(1, on: at(2026, 1, 5), of: p)]
        let dueAt = at(2026, 1, 12)

        #expect(status(shots, p, at: at(2026, 1, 14, 8))
            == NextDoseStatus.overdue(dueAt: dueAt, daysLate: 2))
        #expect(status(shots, p, at: at(2026, 1, 13, 0, 0, 0))
            == NextDoseStatus.overdue(dueAt: dueAt, daysLate: 1))
        #expect(status(shots, p, at: at(2026, 1, 12, 23, 59, 59))
            == NextDoseStatus.overdue(dueAt: dueAt, daysLate: 0))
    }

    @Test("logging the shot clears the overdue state")
    func loggingClearsOverdue() {
        let p = profile(1)
        let first = shot(1, on: at(2026, 1, 5), of: p)
        let now = at(2026, 1, 14, 8)

        #expect(status([first], p, at: now)
            == NextDoseStatus.overdue(dueAt: at(2026, 1, 12), daysLate: 2))
        #expect(status([first, shot(2, on: now, of: p)], p, at: now)
            == NextDoseStatus.upcoming(dueAt: at(2026, 1, 21, 8)))
    }

    // MARK: calendar-aware day arithmetic

    @Test("across the fall-back Sunday the wall-clock time is kept")
    func dstFallBack() throws {
        let p = profile(1)
        let shotAt = at(2026, 10, 28)
        let shots = [shot(1, on: shotAt, of: p)]
        let next = try #require(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal))

        #expect(next == at(2026, 11, 4))
        // Seven days plus the repeated hour.
        #expect(next.timeIntervalSince(shotAt) == 169 * 3600)
    }

    @Test("across the spring-forward Sunday the wall-clock time is kept")
    func dstSpringForward() throws {
        let p = profile(1)
        let shotAt = at(2026, 3, 4)
        let shots = [shot(1, on: shotAt, of: p)]
        let next = try #require(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal))

        #expect(next == at(2026, 3, 11))
        // Seven days less the skipped hour.
        #expect(next.timeIntervalSince(shotAt) == 167 * 3600)
    }

    @Test("the injected calendar's time zone drives the arithmetic")
    func utcCalendarHasNoDST() throws {
        let p = profile(1)
        // 2026-10-28 09:00 in Halifax is 12:00 UTC, across the same fall-back.
        let shotAt = at(2026, 10, 28)
        let shots = [shot(1, on: shotAt, of: p)]
        let next = try #require(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: utc))

        #expect(next == utcAt(2026, 11, 4, 12))
        #expect(next.timeIntervalSince(shotAt) == 168 * 3600)
    }

    @Test("days late is calendar days even across the fall-back day")
    func daysLateAcrossFallBack() {
        let p = profile(1)
        // Due 2026-11-01 09:00, on the 25-hour day.
        let shots = [shot(1, on: at(2026, 10, 25), of: p)]
        let dueAt = at(2026, 11, 1)
        #expect(NextDose.nextDoseAt(shots: shots, activeProfile: p, calendar: cal) == dueAt)
        #expect(status(shots, p, at: at(2026, 11, 3))
            == NextDoseStatus.overdue(dueAt: dueAt, daysLate: 2))
    }
}

/// Builds a wall-clock instant in the given calendar's time zone.
private func makeDate(
    in calendar: Calendar,
    _ y: Int,
    _ mo: Int,
    _ d: Int,
    _ h: Int,
    _ mi: Int,
    _ s: Int
) -> Date {
    let components = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    guard let date = calendar.date(from: components) else {
        preconditionFailure("fixture \(y)-\(mo)-\(d) \(h):\(mi):\(s) is not representable")
    }
    return date
}
