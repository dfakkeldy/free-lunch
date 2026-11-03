// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — next-dose projection and the calm overdue state (spec §5 Next dose)
//
// Projection:
// - The next dose is the latest shot's `takenAt` plus the profile's
//   `intervalDays` calendar days, in the injected calendar and its time zone.
//   The wall-clock time is kept across a daylight-saving change, so seven
//   calendar days over a DST change are 169 or 167 elapsed hours, not 168.
// - The latest shot is the one with the greatest `takenAt` (ties broken by
//   id), whatever the input order. A `takenAt` edited after logging counts at
//   its edited time, so a late shot moves every later projection.
// - Only shots whose `medicationID` is the active profile's id count; shots of
//   other profiles are ignored.
// - No projection without an active profile, for an archived profile, with no
//   shots for that profile, or with a non-positive interval.
//
// Overdue boundary:
// - Overdue begins strictly after the projected instant. At exactly
//   `nextDoseAt` the dose is due today; one second later it is overdue with
//   `daysLate` 0. It does not wait for the end of the calendar day, so the
//   card, the complication and the planner's reminder share one boundary.
// - `daysLate` counts calendar days from the start of the due date to the
//   start of today, so a dose due earlier today is 0 days late.
import Foundation

public enum NextDoseStatus: Sendable, Hashable {
    /// Due on a later calendar day than `now`.
    case upcoming(dueAt: Date)
    /// Due later today, or exactly now.
    case dueToday(dueAt: Date)
    /// Past due. `daysLate` counts calendar days from the due date to today (0 = due earlier today).
    case overdue(dueAt: Date, daysLate: Int)
}

public enum NextDose {
    /// Projects when the next dose is due, or nil when there is nothing to
    /// project from.
    ///
    /// - Parameters:
    ///   - shots: shot events in any order; other profiles' shots are ignored.
    ///   - activeProfile: the medication being tracked, or nil when none is.
    ///   - calendar: supplies both the day length and the time zone.
    /// - Returns: the latest shot's `takenAt` plus `intervalDays` calendar
    ///   days, or nil without an active, unarchived profile with a positive
    ///   interval and at least one shot of its own.
    public static func nextDoseAt(
        shots: [ShotEventData],
        activeProfile: MedicationProfileData?,
        calendar: Calendar
    ) -> Date? {
        guard let profile = activeProfile,
              profile.archivedAt == nil,
              profile.intervalDays > 0
        else { return nil }

        let latest = shots
            .filter { $0.medicationID == profile.id }
            .max { lhs, rhs in
                if lhs.takenAt != rhs.takenAt { return lhs.takenAt < rhs.takenAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard let latest else { return nil }

        return calendar.date(byAdding: .day, value: profile.intervalDays, to: latest.takenAt)
    }

    /// The next dose's calm state at `now`, or nil when nothing is projected.
    ///
    /// Overdue begins strictly after the projected instant; at exactly that
    /// instant the dose is still due today.
    ///
    /// - Parameters:
    ///   - shots: shot events in any order.
    ///   - activeProfile: the medication being tracked, or nil when none is.
    ///   - now: the instant to judge.
    ///   - calendar: supplies both the day boundaries and the time zone.
    public static func status(
        shots: [ShotEventData],
        activeProfile: MedicationProfileData?,
        now: Date,
        calendar: Calendar
    ) -> NextDoseStatus? {
        guard let dueAt = nextDoseAt(
            shots: shots,
            activeProfile: activeProfile,
            calendar: calendar
        ) else { return nil }

        if now > dueAt {
            let daysLate = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: dueAt),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
            return .overdue(dueAt: dueAt, daysLate: daysLate)
        }
        if calendar.isDate(now, inSameDayAs: dueAt) {
            return .dueToday(dueAt: dueAt)
        }
        return .upcoming(dueAt: dueAt)
    }
}
