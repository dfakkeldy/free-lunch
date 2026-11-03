// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — dose-strength periods (spec §1, acceptance #8; report fields §5)
//
// Periods are derived at query time from the shot history and never stored.
//
// Boundaries:
// - Shots are ordered by `takenAt` (ties broken by id), whatever the input
//   order.
// - A new period starts at the first shot whose dose or medication differs
//   from the shot before it. A dose that returns to an earlier strength
//   starts a new period; periods are never merged.
// - Doses compare at microgram resolution, so 0.5 mg and 500 µg are equal.
// - A closed period is [its first shot, the first shot of the next period).
// - The last period is open: [its first shot, asOf], extended to its last
//   shot if that is later than asOf.
//
// Reports:
// - injectionCount: shots inside the period.
// - durationDays: elapsed seconds / 86 400 (calendar-free).
// - expectedInjections: durationDays / the medication's intervalDays.
// - coverage: injectionCount / expectedInjections, uncapped (can exceed 1).
//   nil when the medication profile is unknown or the period has no length.
// - totalChangeKg: trend weight at the end minus trend weight at the start.
//   FLCore has no trend model (that is spec §3), so the caller supplies the
//   trend lookup; nil when either boundary has no trend value.
// - weeklyRateKg: totalChangeKg / (durationDays / 7).
//
// Membership (`contains`) follows the same boundaries, by instant, never by
// calendar day: [start, end) for a closed period, [start, end] for the open
// one. A record stamped exactly at a closed period's end belongs to the next
// period, and one stamped just before it, even on the same calendar day,
// belongs to this one.
import Foundation

public struct DosePeriod: Sendable, Hashable {
    public let medicationID: UUID
    public let doseMg: Double
    public let start: Date
    public let end: Date
    /// True for the last period, which runs to `asOf`.
    public let isOpen: Bool
    /// The period's shots in time order.
    public let shotIDs: [UUID]
    /// The medication's interval, or nil when no profile was supplied for it.
    public let intervalDays: Int?
    public let trendAtStartKg: Double?
    public let trendAtEndKg: Double?

    public var injectionCount: Int { shotIDs.count }

    public var durationDays: Double {
        end.timeIntervalSince(start) / DosePeriodDerivation.secondsPerDay
    }

    public var expectedInjections: Double? {
        guard let intervalDays, intervalDays > 0 else { return nil }
        return durationDays / Double(intervalDays)
    }

    public var coverage: Double? {
        guard let expected = expectedInjections, expected > 0 else { return nil }
        return Double(injectionCount) / expected
    }

    public var totalChangeKg: Double? {
        guard let trendAtStartKg, let trendAtEndKg else { return nil }
        return trendAtEndKg - trendAtStartKg
    }

    public var weeklyRateKg: Double? {
        guard let change = totalChangeKg, durationDays > 0 else { return nil }
        return change / (durationDays / 7)
    }

    /// Whether `instant` falls in this period: half-open `[start, end)` when
    /// closed, closed `[start, end]` when open (the open period includes
    /// `asOf`, its end).
    public func contains(_ instant: Date) -> Bool {
        guard instant >= start else { return false }
        return isOpen ? instant <= end : instant < end
    }
}

public enum DosePeriodDerivation {
    static let secondsPerDay: Double = 86_400

    /// Derives the dose-strength periods for a shot history.
    ///
    /// - Parameters:
    ///   - shots: shot events in any order.
    ///   - profiles: medication profiles; supply the interval for coverage.
    ///   - asOf: the end of the open last period, usually now.
    ///   - trendKg: trend weight at a date, or nil where none is known.
    public static func periods(
        shots: [ShotEventData],
        profiles: [MedicationProfileData],
        asOf: Date,
        trendKg: (Date) -> Double? = { _ in nil }
    ) -> [DosePeriod] {
        let ordered = shots.sorted { lhs, rhs in
            if lhs.takenAt != rhs.takenAt { return lhs.takenAt < rhs.takenAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard !ordered.isEmpty else { return [] }

        var intervals: [UUID: Int] = [:]
        for profile in profiles where intervals[profile.id] == nil {
            intervals[profile.id] = profile.intervalDays
        }

        var groups: [[ShotEventData]] = []
        for shot in ordered {
            if let previous = groups.last?.last, sameStrength(previous, shot) {
                groups[groups.count - 1].append(shot)
            } else {
                groups.append([shot])
            }
        }

        var result: [DosePeriod] = []
        result.reserveCapacity(groups.count)
        for (index, group) in groups.enumerated() {
            let first = group[0]
            let isOpen = index == groups.count - 1
            let end: Date
            if isOpen {
                end = max(asOf, group[group.count - 1].takenAt)
            } else {
                end = groups[index + 1][0].takenAt
            }
            result.append(
                DosePeriod(
                    medicationID: first.medicationID,
                    doseMg: first.doseMg,
                    start: first.takenAt,
                    end: end,
                    isOpen: isOpen,
                    shotIDs: group.map(\.id),
                    intervalDays: intervals[first.medicationID],
                    trendAtStartKg: trendKg(first.takenAt),
                    trendAtEndKg: trendKg(end)
                )
            )
        }
        return result
    }

    static func sameStrength(_ lhs: ShotEventData, _ rhs: ShotEventData) -> Bool {
        guard lhs.medicationID == rhs.medicationID else { return false }
        let lhsMicrograms = lhs.doseMg * 1_000
        let rhsMicrograms = rhs.doseMg * 1_000
        // A dose too large to scale stays finite in mg; compare it exactly
        // so two different huge doses never collapse to inf == inf.
        guard lhsMicrograms.isFinite, rhsMicrograms.isFinite else {
            return lhs.doseMg == rhs.doseMg
        }
        return lhsMicrograms.rounded() == rhsMicrograms.rounded()
    }
}
