// SPDX-License-Identifier: GPL-3.0-or-later
// FLFixtures — synthetic history for the dose-period reports (spec §5
// acceptance #5). Every value is invented.
//
// Days count from `DosePeriodFixtures.anchor` in 86 400-second steps.
//
//   0.25 mg: shots days 0, 3, 5          period [0, 7)
//   0.50 mg: shot  day 7                 period [7, 10)
//   1.00 mg: shot  day 10                open period [10, 24], asOf day 24
//
// Weigh-ins are every second day from day -6 to day 12: 80 kg up to day 4,
// then 64 kg. `weighIns` is plain (day, kg) pairs because this module does
// not see the trend engine; the test that binds them to the §3 trend uses
// α = 0.25 so every step factor is a power-of-two fraction.
import FLCore
import Foundation

public enum DosePeriodReportFixtures {
    private typealias F = DosePeriodFixtures

    public static let asOf = F.day(24)

    public static let shots: [ShotEventData] = [
        (1, 0.0, 0.25), (2, 3.0, 0.25), (3, 5.0, 0.25),
        (4, 7.0, 0.5),
        (5, 10.0, 1.0)
    ].map { entry in
        ShotEventData(
            id: F.uuid(entry.0),
            takenAt: F.day(entry.1),
            dose: Milligrams(entry.2),
            medicationID: F.medicationID
        )
    }

    /// (day, kg) every second day, day -6 through day 12.
    public static let weighIns: [(day: Double, kg: Double)] =
        stride(from: -6.0, through: 12.0, by: 2.0).map { ($0, $0 <= 4 ? 80.0 : 64.0) }

    // MARK: Meals

    private static let hour: TimeInterval = 3_600

    private static func meal(
        _ n: Int,
        at date: Date,
        hunger: Int?,
        state: MealState = .logged
    ) -> MealEntryData {
        MealEntryData(
            id: F.uuid(100 + n),
            state: state,
            createdAt: date,
            loggedAt: state == .logged ? date : nil,
            hunger: hunger,
            source: .phone
        )
    }

    /// Meals placed on and around the period boundaries (see the tests for
    /// the period each lands in and why).
    public static let meals: [MealEntryData] = [
        meal(1, at: F.day(-1), hunger: 5),
        meal(2, at: F.day(0), hunger: 3),
        meal(3, at: F.day(2.5), hunger: nil),
        meal(4, at: F.day(7).addingTimeInterval(-hour), hunger: 4),
        meal(5, at: F.day(7), hunger: 2),
        meal(6, at: F.day(8), hunger: nil),
        meal(7, at: F.day(9), hunger: nil),
        meal(8, at: F.day(10), hunger: 5),
        meal(9, at: F.day(12), hunger: nil),
        meal(10, at: F.day(15), hunger: 1),
        meal(11, at: F.day(24), hunger: 1),
        meal(12, at: F.day(24).addingTimeInterval(12 * hour), hunger: 5),
        meal(13, at: F.day(3), hunger: 5, state: .draft)
    ]

    // MARK: Side effects

    private static func effect(_ n: Int, at date: Date, _ type: SideEffectType) -> SideEffectEntryData {
        SideEffectEntryData(id: F.uuid(200 + n), occurredAt: date, type: type, severity: 1)
    }

    public static let sideEffects: [SideEffectEntryData] = [
        effect(1, at: F.day(-2), .nausea),
        effect(2, at: F.day(0), .nausea),
        effect(3, at: F.day(3), .nausea),
        effect(4, at: F.day(7).addingTimeInterval(-hour), .vomiting),
        effect(5, at: F.day(7), .constipation),
        effect(6, at: F.day(9), .nausea),
        effect(7, at: F.day(10), .other("headache")),
        effect(8, at: F.day(11), .other("headache")),
        effect(9, at: F.day(11.5), .other("Dizzy")),
        effect(10, at: F.day(24), .fatigue),
        effect(11, at: F.day(25), .nausea)
    ]
}
