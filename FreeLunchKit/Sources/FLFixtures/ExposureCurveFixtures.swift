// SPDX-License-Identifier: GPL-3.0-or-later
// FLFixtures — synthetic shot series for the exposure curve (spec §5
// acceptance #2 and #3). Every value is invented.
//
// The semaglutide series is `DosePeriodFixtures.shots` (a missed week and
// two strength changes). The tirzepatide series below adds its own gap and
// a late shot. Scripts/exposure-curve-golden.py mirrors both day lists.
//
//   2.5 mg: days 0, 7, 14, 21              (on schedule)
//   5.0 mg: days 28, 35, 49, 57.25, 63     (day 42 missed; 57.25 is 30 h late)
import FLCore
import Foundation

public enum ExposureCurveFixtures {
    public static let anchor = DosePeriodFixtures.anchor

    public static func hour(_ offset: Double) -> Date {
        anchor.addingTimeInterval(offset * 3_600)
    }

    public static let tirzepatideID = DosePeriodFixtures.uuid(901)

    public static let tirzepatideProfile = MedicationProfileData(id: tirzepatideID, known: .tirzepatide)

    public static let tirzepatideShots: [ShotEventData] = {
        let schedule: [(day: Double, mg: Double)] = [
            (0, 2.5), (7, 2.5), (14, 2.5), (21, 2.5),
            (28, 5), (35, 5), (49, 5), (57.25, 5), (63, 5)
        ]
        return schedule.enumerated().map { index, entry in
            ShotEventData(
                id: DosePeriodFixtures.uuid(100 + index),
                takenAt: DosePeriodFixtures.day(entry.day),
                dose: Milligrams(entry.mg),
                medicationID: tirzepatideID
            )
        }
    }()

    /// A never-miss train: `count` shots of `mg`, one every `intervalDays`
    /// from the anchor.
    public static func neverMiss(
        count: Int,
        mg: Double,
        intervalDays: Double,
        medicationID: UUID
    ) -> [ShotEventData] {
        (0..<count).map { index in
            ShotEventData(
                id: DosePeriodFixtures.uuid(500 + index),
                takenAt: DosePeriodFixtures.day(Double(index) * intervalDays),
                dose: Milligrams(mg),
                medicationID: medicationID
            )
        }
    }
}
