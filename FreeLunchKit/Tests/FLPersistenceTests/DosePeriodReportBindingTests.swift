// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5 acceptance #5, end to end: the dose-period reports read their
// trend change from a real §3 `TrendSeries`, not a stub.
//
// Weigh-ins (DosePeriodReportFixtures): every second day from day -6 to day
// 12, 80 kg through day 4 and 64 kg from day 6. Smoothing alpha = 0.25, so a
// two-day step has factor 1 - 0.75^2 = 7/16 and each new 64 kg weigh-in
// leaves (9/16) of the remaining gap:
//
//   trend after n weigh-ins at 64 kg = 64 + 16 * (9/16)^n
//   n = 0 (all 80 kg so far)          = 80
//   n = 1 (day 6)                     = 64 + 9                        = 73
//   n = 3 (day 10)                    = 64 + 16 * 729 / 4096          = 66.84765625
//   n = 4 (day 12)                    = 64 + 16 * 6561 / 65536        = 65.601806640625
//
// The trend is defined from day 0 (fourth weigh-in, spanning 6 days); at day
// -2 it has 3 weigh-ins spanning 4 days and is not. Boundaries:
//   day 0   weigh-in on the boundary instant: 80
//   day 7   no weigh-in that day: holds day 6's 73
//   day 10  weigh-in on the boundary instant (n = 3): 66.84765625
//   day 24  asOf, last weigh-in was day 12: holds 65.601806640625
//
// So: period 1 change 73 - 80 = -7, weekly -7;
//     period 2 change 66.84765625 - 73 = -6.15234375, weekly -14.35546875;
//     period 3 change 65.601806640625 - 66.84765625 = -1.245849609375,
//     weekly -0.6229248046875. (The coverage and count vectors are worked in
//     the FLCore suite; these tests check the trend binding.)
import FLCore
import FLEnergyCore
import FLFixtures
import Foundation
import Testing
@testable import FLPersistence

private typealias F = DosePeriodFixtures
private typealias R = DosePeriodReportFixtures

private func series(
    _ weighIns: [(day: Double, kg: Double)] = R.weighIns
) -> TrendSeries {
    TrendWeight.series(
        samples: weighIns.map { WeightSample(measuredAt: F.day($0.day), weightKg: $0.kg) },
        smoothing: TrendSmoothing(alpha: 0.25)!
    )
}

private func boundReports(_ trend: TrendSeries) -> [DosePeriodReport] {
    DosePeriodReports.reports(
        shots: R.shots,
        profiles: [F.profile],
        meals: R.meals,
        sideEffects: R.sideEffects,
        asOf: R.asOf,
        trend: trend
    )
}

@Suite("Dose-period reports bound to the weight trend")
struct DosePeriodReportBindingTests {
    @Test("trend change and weekly rate per period match the hand-worked values")
    func goldenTrendChange() {
        let reports = boundReports(series())

        #expect(reports.map(\.period.trendAtStartKg) == [80, 73, 66.84765625])
        #expect(reports.map(\.period.trendAtEndKg) == [73, 66.84765625, 65.601806640625])
        #expect(reports.map(\.totalChangeKg) == [-7, -6.15234375, -1.245849609375])
        #expect(reports[0].weeklyRateKg == -7)
        #expect(abs(reports[1].weeklyRateKg! - -14.35546875) < 1e-12)
        #expect(abs(reports[2].weeklyRateKg! - -0.6229248046875) < 1e-12)
    }

    @Test("a boundary with no weigh-in that day holds the last trend")
    func heldAcrossGaps() {
        // Day 7 has no weigh-in (its latest is day 6) and neither does asOf
        // (day 24; its latest is day 12): both hold the earlier value rather
        // than become unknown or extrapolate.
        let reports = boundReports(series())
        #expect(reports[0].period.trendAtEndKg == 73)
        #expect(reports[1].period.trendAtStartKg == 73)
        #expect(reports[2].period.trendAtEndKg == 65.601806640625)
    }

    @Test("a boundary before the trend is defined gives no change, not zero")
    func undefinedAtStart() {
        // Weigh-ins from day 0: at day 0 there is one sample, so the trend is
        // undefined at period 1's start. At day 7 the samples are days 0, 2, 4
        // and 6 (4 samples spanning 6 days), so the trend is defined: 73.
        let late = R.weighIns.filter { $0.day >= 0 }
        let reports = boundReports(series(late))
        #expect(reports[0].period.trendAtStartKg == nil)
        #expect(reports[0].totalChangeKg == nil)
        #expect(reports[0].weeklyRateKg == nil)
        #expect(reports[1].totalChangeKg != nil)
        #expect(reports[0].coverage == 3)
    }

    @Test("no weigh-ins at all: counts still reported, trend change nil everywhere")
    func noWeighIns() {
        let reports = boundReports(series([]))
        #expect(reports.map(\.totalChangeKg) == [nil, nil, nil])
        #expect(reports.map(\.weeklyRateKg) == [nil, nil, nil])
        #expect(reports.map(\.injectionCount) == [3, 1, 1])
        #expect(reports.map(\.hunger.unknownCount) == [1, 2, 1])
    }
}
