// SPDX-License-Identifier: GPL-3.0-or-later
// FLFixtures — synthetic weekly-shot history with two strength changes
// (spec §1 acceptance #8). Every value is invented.
//
// Days are counted from `anchor` in whole 86 400-second steps, so nothing
// depends on a calendar or time zone.
//
//   0.25 mg: days 0, 7, 14, 21             (on schedule)
//   0.50 mg: days 28, 35, 49, 56           (day 42 missed)
//   1.00 mg: days 63, 69, 75, 81           (every 6 days; open period)
//   asOf:    day 84
//
// Synthetic trend weight is known only at the period boundaries:
//   day 0: 104.0 kg, day 28: 101.0 kg, day 63: 98.5 kg, day 84: 97.25 kg
import FLCore
import Foundation

public enum DosePeriodFixtures {
    /// 2026-01-05 08:00:00 UTC.
    public static let anchor = Date(timeIntervalSince1970: 1_767_600_000)

    public static func day(_ offset: Double) -> Date {
        anchor.addingTimeInterval(offset * 86_400)
    }

    /// Deterministic UUIDs: 00000000-0000-0000-0000-<n, 12 digits>.
    public static func uuid(_ n: Int) -> UUID {
        let digits = String(n)
        let padded = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
        return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
    }

    public static let medicationID = uuid(900)

    public static let profile = MedicationProfileData(id: medicationID, known: .semaglutide)

    public static let asOf = day(84)

    public static let shots: [ShotEventData] = {
        let schedule: [(day: Double, mg: Double, site: InjectionSite?)] = [
            (0, 0.25, .abdomenLeft),
            (7, 0.25, .abdomenRight),
            (14, 0.25, nil),
            (21, 0.25, .thighLeft),
            (28, 0.5, .thighRight),
            (35, 0.5, nil),
            (49, 0.5, .armLeft),
            (56, 0.5, .armRight),
            (63, 1.0, .abdomenLeft),
            (69, 1.0, nil),
            (75, 1.0, .other1),
            (81, 1.0, .other2)
        ]
        return schedule.enumerated().map { index, entry in
            ShotEventData(
                id: uuid(index + 1),
                takenAt: day(entry.day),
                dose: Milligrams(entry.mg),
                medicationID: medicationID,
                site: entry.site,
                source: index.isMultiple(of: 3) ? .watch : .phone
            )
        }
    }()

    public static let trendByDay: [Double: Double] = [
        0: 104.0,
        28: 101.0,
        63: 98.5,
        84: 97.25
    ]

    /// Trend lookup for the derivation: a value only at the known days.
    public static func trendKg(at date: Date) -> Double? {
        let offset = date.timeIntervalSince(anchor) / 86_400
        return trendByDay[offset]
    }
}
