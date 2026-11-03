// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5 acceptance #5 and the hunger / side-effect counts: golden vectors
// worked by hand for DosePeriodReportFixtures (days from the anchor).
//
// Periods (interval 7 days, so expected injections = days / 7):
//
//   period   dose  span (days)  shots  expected  coverage
//   1        0.25  [0, 7)       3      1         3        (300%)
//   2        0.50  [7, 10)      1      3/7       7/3      (233%)
//   3 open   1.00  [10, 24]     1      2         1/2
//
// Trend held at each boundary (worked in the persistence binding test, from
// weigh-ins at alpha 0.25; this suite takes them as given):
//   day 0: 80, day 7: 73, day 10: 66.84765625, day 24: 65.601806640625
//
//   period 1 change  73 - 80                       = -7
//            weekly  -7 / (7 / 7)                  = -7
//   period 2 change  66.84765625 - 73              = -6.15234375
//            weekly  -6.15234375 / (3 / 7)         = -14.35546875
//   period 3 change  65.601806640625 - 66.84765625 = -1.245849609375
//            weekly  -1.245849609375 / (14 / 7)    = -0.6229248046875
//
// Hunger, meals placed by loggedAt (day -1 and the day-24-plus-12h meal are
// outside every period; the draft is never counted):
//   period 1  day 0 (=3, boundary start), day 2.5 (unknown), day 7 minus 1h (=4)
//             rated 2 (levels 3 and 4), unknown 1, mean (3 + 4) / 2 = 3.5
//   period 2  day 7 (=2, the new period owns its start instant), day 8, day 9
//             rated 1 (level 2), unknown 2, mean 2
//   period 3  day 10 (=5), day 12 (unknown), day 15 (=1), day 24 (=1, asOf
//             belongs to the open period)
//             rated 3 (levels 5, 1, 1), unknown 1, mean 7 / 3
//
// Side effects, placed by occurredAt (day -2 and day 25 are outside):
//   period 1  nausea day 0, nausea day 3, vomiting day 7 minus 1h
//             nausea 2, vomiting 1, total 3
//   period 2  constipation day 7, nausea day 9
//             constipation 1, nausea 1, total 2
//   period 3  other("headache") days 10 and 11, other("Dizzy") day 11.5,
//             fatigue day 24
//             headache 2, Dizzy 1, fatigue 1, total 4
import FLCore
import FLFixtures
import Foundation
import Testing

private typealias F = DosePeriodFixtures
private typealias R = DosePeriodReportFixtures

private func heldTrend(_ date: Date) -> Double? {
    switch date.timeIntervalSince(F.anchor) / 86_400 {
    case 0: 80
    case 7: 73
    case 10: 66.84765625
    case 24: 65.601806640625
    default: nil
    }
}

private func goldenReports(trend: @escaping (Date) -> Double? = heldTrend) -> [DosePeriodReport] {
    DosePeriodReports.reports(
        shots: R.shots,
        profiles: [F.profile],
        meals: R.meals,
        sideEffects: R.sideEffects,
        asOf: R.asOf,
        trendKg: trend
    )
}

@Suite("Dose-period reports")
struct DosePeriodReportTests {
    @Test("period table: duration, injections, coverage above and below 100%")
    func table() {
        let reports = goldenReports()
        #expect(reports.map(\.durationDays) == [7, 3, 14])
        #expect(reports.map(\.injectionCount) == [3, 1, 1])
        #expect(reports.map(\.period.expectedInjections) == [1, 3.0 / 7, 2])
        #expect(reports[0].coverage == 3)
        #expect(abs(reports[1].coverage! - 7.0 / 3) < 1e-12)
        #expect(reports[2].coverage == 0.5)
        #expect(reports[0].coverage! > 1 && reports[1].coverage! > 1)
    }

    @Test("trend change and weekly rate per period")
    func trendChange() {
        let reports = goldenReports()
        #expect(reports.map(\.totalChangeKg) == [-7, -6.15234375, -1.245849609375])
        #expect(reports[0].weeklyRateKg == -7)
        #expect(abs(reports[1].weeklyRateKg! - -14.35546875) < 1e-12)
        #expect(abs(reports[2].weeklyRateKg! - -0.6229248046875) < 1e-12)
    }

    @Test("a boundary with no trend gives no change and no weekly rate, nothing guessed")
    func noTrendAtBoundary() {
        // Trend known at day 7 and day 10 only: period 1 lacks its start,
        // period 3 lacks its end. Period 2 is unaffected.
        let reports = goldenReports { date in
            switch date.timeIntervalSince(F.anchor) / 86_400 {
            case 7: 73
            case 10: 66.84765625
            default: nil
            }
        }
        #expect(reports.map(\.totalChangeKg) == [nil, -6.15234375, nil])
        #expect(reports[0].weeklyRateKg == nil)
        #expect(reports[2].weeklyRateKg == nil)
        // Everything that does not need a trend is still reported.
        #expect(reports.map(\.injectionCount) == [3, 1, 1])
        #expect(reports[0].coverage == 3)
    }

    @Test("hunger: mean and count per period, unknown counted exactly and never imputed")
    func hunger() {
        let hunger = goldenReports().map(\.hunger)

        #expect(hunger.map(\.ratedCount) == [2, 1, 3])
        #expect(hunger.map(\.unknownCount) == [1, 2, 1])
        #expect(hunger.map(\.mealCount) == [3, 3, 4])
        #expect(hunger.map(\.mean) == [3.5, 2, 7.0 / 3])
        #expect(hunger[0].countsByLevel == [1: 0, 2: 0, 3: 1, 4: 1, 5: 0])
        #expect(hunger[1].countsByLevel == [1: 0, 2: 1, 3: 0, 4: 0, 5: 0])
        #expect(hunger[2].countsByLevel == [1: 2, 2: 0, 3: 0, 4: 0, 5: 1])
    }

    @Test("hunger boundaries: the instant of a new strength belongs to the new period")
    func hungerBoundary() {
        // Day 7 minus one hour (hunger 4) is the old period; day 7 itself
        // (hunger 2) is the new one, though both are on the same shot day.
        let hunger = goldenReports().map(\.hunger)
        #expect(hunger[0].countsByLevel[4] == 1)
        #expect(hunger[1].countsByLevel[2] == 1)
        #expect(hunger[0].countsByLevel[2] == 0)
    }

    @Test("a period whose meals all lack hunger has no mean, not zero")
    func allUnknown() {
        let meals = [
            MealEntryData(createdAt: F.day(1), loggedAt: F.day(1), source: .phone),
            MealEntryData(createdAt: F.day(2), loggedAt: F.day(2), source: .phone)
        ].map { meal -> MealEntryData in
            var meal = meal
            meal.state = .logged
            return meal
        }
        let reports = DosePeriodReports.reports(
            shots: R.shots, profiles: [F.profile], meals: meals, sideEffects: [], asOf: R.asOf
        )
        #expect(reports[0].hunger.ratedCount == 0)
        #expect(reports[0].hunger.unknownCount == 2)
        #expect(reports[0].hunger.mean == nil)
        // Periods with no meals at all report zero of everything.
        #expect(reports[1].hunger.mealCount == 0)
        #expect(reports[1].hunger.mean == nil)
    }

    @Test("an out-of-range hunger value is unknown, never rated")
    func invalidHunger() {
        let summary = HungerSummary(ratings: [0, 6, -1, 3, nil, 5])
        #expect(summary.ratedCount == 2)
        #expect(summary.unknownCount == 4)
        #expect(summary.mean == 4)
    }

    @Test("side effects: counts by type per period, boundaries by instant")
    func sideEffects() {
        let effects = goldenReports().map(\.sideEffects)

        #expect(effects[0].countsByType == [.nausea: 2, .vomiting: 1])
        #expect(effects[1].countsByType == [.constipation: 1, .nausea: 1])
        #expect(effects[2].countsByType == [.other("headache"): 2, .other("Dizzy"): 1, .fatigue: 1])
        #expect(effects.map(\.totalCount) == [3, 2, 4])
    }

    @Test("records before the first shot or after asOf are in no period")
    func outsidePeriods() {
        let reports = goldenReports()
        let rated = reports.map(\.hunger.mealCount).reduce(0, +)
        let effects = reports.map(\.sideEffects.totalCount).reduce(0, +)
        // 13 meals: one before day 0, one after asOf, one draft.
        #expect(R.meals.count == 13)
        #expect(rated == 10)
        // 11 effects: one before day 0, one after asOf.
        #expect(R.sideEffects.count == 11)
        #expect(effects == 9)
    }

    @Test("contains: closed periods are half-open, the open period includes asOf")
    func containsConvention() {
        let periods = goldenReports().map(\.period)
        #expect(periods[0].contains(F.day(0)))
        #expect(periods[0].contains(F.day(7).addingTimeInterval(-1)))
        #expect(!periods[0].contains(F.day(7)))
        #expect(periods[1].contains(F.day(7)))
        #expect(!periods[0].contains(F.day(0).addingTimeInterval(-1)))
        #expect(periods[2].contains(F.day(24)))
        #expect(!periods[2].contains(F.day(24).addingTimeInterval(1)))
    }

    @Test("no shots, no reports")
    func empty() {
        let reports = DosePeriodReports.reports(
            shots: [], profiles: [], meals: R.meals, sideEffects: R.sideEffects, asOf: R.asOf
        )
        #expect(reports.isEmpty)
    }
}
