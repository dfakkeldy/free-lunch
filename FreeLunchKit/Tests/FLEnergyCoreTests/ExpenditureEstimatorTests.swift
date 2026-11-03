// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLEnergyCore

// Expected values below were computed by hand and cross-checked with a
// throwaway script outside the repo that implements spec §3 FL-EB v1 from
// the formula text; none are taken from this module's output.

// MARK: - Synthetic fixture helpers

/// Gregorian calendar pinned to UTC so "calendar day" is exactly 86 400 s.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// A synthetic UTC midnight (2001-01-01 + 9260 days).
private let origin = Date(timeIntervalSinceReferenceDate: 9_260 * 86_400)

/// Start of fixture day `offset`.
private func day(_ offset: Int) -> Date {
    origin.addingTimeInterval(Double(offset) * 86_400)
}

/// 07:00 on fixture day `offset`.
private func morning(_ offset: Int) -> Date {
    day(offset).addingTimeInterval(7 * 3_600)
}

/// 12:30 on fixture day `offset`.
private func noon(_ offset: Int) -> Date {
    day(offset).addingTimeInterval(12.5 * 3_600)
}

private func logged(_ offset: Int, _ kcal: Double, meals: Int = 2) -> DayIntake {
    DayIntake(day: noon(offset), intakeKcal: kcal, evidence: DayIntakeEvidence(loggedMealCount: meals))
}

private func reconstructed(_ offset: Int, _ kcal: Double, markedDidNotTrack: Bool = false) -> DayIntake {
    DayIntake(
        day: noon(offset),
        intakeKcal: kcal,
        evidence: DayIntakeEvidence(hasReconstructedDietaryEnergy: true, markedDidNotTrack: markedDidNotTrack)
    )
}

private func weighIns(_ pairs: [(Int, Double)]) -> TrendSeries {
    TrendWeight.series(samples: pairs.map { WeightSample(measuredAt: morning($0.0), weightKg: $0.1) })
}

/// A trend series with hand-set trend values, to test the estimator apart
/// from the smoothing.
private func handSetTrend(_ points: [(Date, Double)]) -> TrendSeries {
    TrendSeries(
        smoothing: .standard,
        points: points.map { TrendPoint(measuredAt: $0.0, weightKg: $0.1, trendKg: $0.1) }
    )
}

private func expectClose(
    _ actual: Double?,
    _ expected: Double,
    tolerance: Double = 1e-9,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let actual else {
        Issue.record("expected \(expected), got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(abs(actual - expected) <= tolerance, "\(actual) vs \(expected)", sourceLocation: sourceLocation)
}

private func evaluate(
    on offset: Int,
    _ intake: [DayIntake],
    _ weights: TrendSeries,
    calendar: Calendar = utc,
    parameters: ExpenditureParameters = .standard
) -> ExpenditureEvaluation {
    ExpenditureEstimator.evaluate(
        on: noon(offset), intake: intake, weights: weights, calendar: calendar, parameters: parameters
    )
}

// MARK: - Shared simple fixture

/// Steady 80.0 kg weigh-ins every morning, days 0–40: the trend is exactly
/// 80.0 wherever it is defined, so Δtrend = 0 and expenditure equals the
/// mean intake.
private let flatWeights = weighIns((0...40).map { ($0, 80.0) })

/// Logged days 7–20 only, intake 2000 + 10·d kcal. Mean over all 14 = 2135.
private let fourteenLoggedDays = (7...20).map { logged($0, 2_000 + 10 * Double($0)) }

// MARK: - Constants and parameters

@Suite("Expenditure estimator: FL-EB v1 constants (spec §3)")
struct ExpenditureConstantsTests {
    @Test("W = 21 days, gate = 14 days, ρ = 7700 kcal/kg, identifier FL-EB v1")
    func constants() {
        #expect(ExpenditureFormulaV1.windowDays == 21)
        #expect(ExpenditureFormulaV1.minimumCompleteIntakeDays == 14)
        #expect(ExpenditureFormulaV1.defaultEnergyDensityKcalPerKg == 7_700)
        #expect(ExpenditureParameters.standard.energyDensityKcalPerKg == 7_700)
        #expect(ExpenditureFormulaV1.identifier == "FL-EB v1")
    }

    @Test("ρ override must be finite and positive", arguments: [0.0, -7_700, .nan, .infinity])
    func rejectsBadDensity(rho: Double) {
        #expect(ExpenditureParameters(energyDensityKcalPerKg: rho) == nil)
    }

    @Test("an overridden ρ is used: Δtrend −1 kg at ρ = 7000 adds exactly 7000/21 kcal/day")
    func overriddenDensity() throws {
        let rho = try #require(ExpenditureParameters(energyDensityKcalPerKg: 7_000))
        let trend = handSetTrend([(morning(6), 81.0), (morning(10), 80.5), (morning(27), 80.0)])
        let estimate = try #require(evaluate(on: 28, fourteenLoggedDays, trend, parameters: rho).estimate)
        // 2135 + 1 × 7000 / 21 = 2135 + 333.333… = 2468.333…
        expectClose(estimate.kcalPerDay, 2_135 + 7_000.0 / 21)
        #expect(estimate.energyDensityKcalPerKg == 7_000)
    }
}

// MARK: - Acceptance #1: golden vectors

/// A 40-day synthetic fixture with weigh-in gaps (including a 3-day gap,
/// days 9–11), nothing-logged days, a day marked "didn't track" (with meals
/// and a large total that must not count) and a reconstructed import day.
private enum Golden {
    static let baseWeights: [(Int, Double)] = [
        (0, 92.4), (1, 91.64), (2, 91.98), (3, 92.02), (5, 92.1), (6, 91.34), (7, 91.68),
        (8, 91.72), (12, 91.38), (13, 91.42), (14, 90.76), (15, 91.5), (16, 90.74),
        (18, 91.12), (19, 90.46), (20, 91.2), (21, 90.44), (22, 90.78), (23, 90.82),
        (27, 90.48), (28, 90.52), (29, 89.86), (30, 90.6), (31, 89.84), (32, 90.18),
        (33, 90.22), (34, 89.56), (35, 90.3), (36, 89.54), (37, 89.88), (38, 89.92),
        (39, 89.26)
    ]

    /// The corrected weight view after a Correction replaces day 20's
    /// weigh-in (91.2 → 90.1). The engine only ever sees the corrected view.
    static let correctedWeights: [(Int, Double)] = baseWeights.map { $0.0 == 20 ? (20, 90.1) : $0 }

    /// Missing (nothing logged): 2, 5, 8, 16, 19, 22, 23, 27, 28, 29.
    /// Day 13 is marked "didn't track"; day 18 is a reconstructed import.
    static let baseIntake: [DayIntake] = [
        logged(0, 2_000), logged(1, 2_037), logged(3, 2_111), logged(4, 2_148),
        logged(6, 2_222), logged(7, 2_259), logged(9, 2_033), logged(10, 2_070),
        logged(11, 2_107), logged(12, 2_144),
        DayIntake(
            day: noon(13),
            intakeKcal: 3_600,
            evidence: DayIntakeEvidence(loggedMealCount: 3, markedDidNotTrack: true)
        ),
        logged(14, 2_218), logged(15, 2_255), logged(17, 2_029), reconstructed(18, 2_150),
        logged(20, 2_140), logged(21, 2_177), logged(24, 2_288), logged(25, 2_025),
        logged(26, 2_062), logged(30, 2_210), logged(31, 2_247), logged(32, 2_284),
        logged(33, 2_021), logged(34, 2_058), logged(35, 2_095), logged(36, 2_132),
        logged(37, 2_169), logged(38, 2_206), logged(39, 2_243)
    ]

    /// A backfill edit: day 22, previously empty, gets 2440 kcal logged.
    static let backfilledIntake: [DayIntake] = baseIntake + [logged(22, 2_440)]

    struct Expected {
        let day: Int
        let state: ExpenditureState
        /// (n_complete, mean intake, Δtrend, expenditure) when tracking.
        let values: (Int, Double, Double, Double)?
        /// The as-of day of the displayed estimate, nil if none yet.
        let displayedAsOf: Int?
    }

    static let baseSequence: [Expected] = [
        // Days 22–26: the trend just before the window's first day is not
        // yet defined (first defined at day 5), so Δtrend over 21 days is
        // not available.
        .init(day: 22, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 23, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 24, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 25, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 26, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 27, state: .tracking,
              values: (15, 2_145.266666666667, -1.048868921331362, 2_529.8519378214996), displayedAsOf: 27),
        .init(day: 28, state: .tracking,
              values: (14, 2_139.785714285714, -1.20141189504551, 2_580.3034091357345), displayedAsOf: 28),
        .init(day: 29, state: .paused(.insufficientIntake), values: nil, displayedAsOf: 28),
        .init(day: 30, state: .paused(.insufficientIntake), values: nil, displayedAsOf: 28),
        .init(day: 31, state: .paused(.insufficientIntake), values: nil, displayedAsOf: 28),
        .init(day: 32, state: .paused(.insufficientIntake), values: nil, displayedAsOf: 28),
        .init(day: 33, state: .paused(.insufficientIntake), values: nil, displayedAsOf: 28),
        .init(day: 34, state: .paused(.insufficientIntake), values: nil, displayedAsOf: 28),
        .init(day: 35, state: .tracking,
              values: (14, 2_154.5714285714284, -1.2971516810233936, 2_630.1937116133395), displayedAsOf: 35),
        .init(day: 36, state: .tracking,
              values: (14, 2_145.785714285714, -1.2134365129210494, 2_590.712435690099), displayedAsOf: 36),
        .init(day: 37, state: .tracking,
              values: (14, 2_137.0, -1.2880928616289395, 2_609.300715930611), displayedAsOf: 37)
    ]

    /// Backfilled day 22 and corrected day-20 weigh-in together.
    static let editedSequence: [Expected] = [
        .init(day: 22, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 23, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 24, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 25, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 26, state: .paused(.insufficientWeight), values: nil, displayedAsOf: nil),
        .init(day: 27, state: .tracking,
              values: (16, 2_163.6875, -1.1290589213313496, 2_577.675771154828), displayedAsOf: 27),
        .init(day: 28, state: .tracking,
              values: (15, 2_159.8, -1.2540245540455004, 2_619.609003150017), displayedAsOf: 28),
        .init(day: 29, state: .tracking,
              values: (14, 2_152.714285714286, -1.24462209864096, 2_609.075721882638), displayedAsOf: 29),
        .init(day: 30, state: .tracking,
              values: (14, 2_152.714285714286, -1.306159888776861, 2_631.6395782658014), displayedAsOf: 30),
        .init(day: 31, state: .tracking,
              values: (14, 2_165.3571428571427, -1.321411629259174, 2_649.874740252173), displayedAsOf: 31),
        .init(day: 32, state: .tracking,
              values: (14, 2_178.0, -1.4111381956932547, 2_695.4173384208602), displayedAsOf: 32),
        .init(day: 33, state: .tracking,
              values: (14, 2_190.6428571428573, -1.4578921054839213, 2_725.2032958202954), displayedAsOf: 33),
        .init(day: 34, state: .tracking,
              values: (14, 2_181.8571428571427, -1.2625735030264877, 2_644.8007606335213), displayedAsOf: 34),
        .init(day: 35, state: .tracking,
              values: (15, 2_173.6, -1.322316152723829, 2_658.449255998737), displayedAsOf: 35),
        .init(day: 36, state: .tracking,
              values: (15, 2_165.4, -1.2360845374514469, 2_618.6309970655307), displayedAsOf: 36),
        .init(day: 37, state: .tracking,
              values: (15, 2_157.2, -1.3084760837062959, 2_636.9745640256415), displayedAsOf: 37)
    ]

    static func check(
        _ snapshots: [ExpenditureSnapshot],
        against expected: [Expected],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(snapshots.count == expected.count, sourceLocation: sourceLocation)
        for (snapshot, want) in zip(snapshots, expected) {
            #expect(snapshot.day == day(want.day), "day \(want.day)", sourceLocation: sourceLocation)
            #expect(snapshot.state == want.state, "day \(want.day)", sourceLocation: sourceLocation)
            #expect(snapshot.displayed?.asOf == want.displayedAsOf.map(day), "day \(want.day)",
                    sourceLocation: sourceLocation)
            guard let values = want.values else {
                #expect(snapshot.evaluation.estimate == nil, "day \(want.day)", sourceLocation: sourceLocation)
                continue
            }
            let (count, mean, delta, kcal) = values
            guard let estimate = snapshot.evaluation.estimate else {
                Issue.record("day \(want.day): expected an estimate", sourceLocation: sourceLocation)
                continue
            }
            #expect(estimate.completeIntakeDays == count, "day \(want.day)", sourceLocation: sourceLocation)
            // Integer kcal sums divided once: exact.
            #expect(estimate.meanIntakeKcal == mean, "day \(want.day)", sourceLocation: sourceLocation)
            expectClose(estimate.trendDeltaKg, delta, tolerance: 1e-12, sourceLocation: sourceLocation)
            expectClose(estimate.kcalPerDay, kcal, sourceLocation: sourceLocation)
            #expect(estimate.asOf == day(want.day), sourceLocation: sourceLocation)
            #expect(estimate.windowFirstDay == day(want.day - 21), sourceLocation: sourceLocation)
            #expect(estimate.windowLastDay == day(want.day - 1), sourceLocation: sourceLocation)
            #expect(estimate.formula == "FL-EB v1", sourceLocation: sourceLocation)
            #expect(snapshot.displayed == estimate, sourceLocation: sourceLocation)
        }
    }
}

@Suite("Expenditure estimator: golden vectors (spec §3 acceptance #1)")
struct ExpenditureGoldenTests {
    @Test("base fixture: trend, state sequence and expenditure per day")
    func baseSequence() {
        let weights = weighIns(Golden.baseWeights)
        // Trend spot checks (α = 0.10): defined from day 5; day 20's value.
        expectClose(weights.trend(asOf: morning(5)), 92.2317384, tolerance: 1e-12)
        expectClose(weights.trend(asOf: morning(20)), 91.36492383905164, tolerance: 1e-12)
        #expect(weights.trend(asOf: morning(3)) == nil)

        let snapshots = ExpenditureEstimator.timeline(
            from: noon(22), through: noon(37), intake: Golden.baseIntake, weights: weights, calendar: utc
        )
        Golden.check(snapshots, against: Golden.baseSequence)
    }

    @Test("backfill edit and weight correction: recomputed sequence")
    func editedSequence() {
        let weights = weighIns(Golden.correctedWeights)
        expectClose(weights.trend(asOf: morning(20)), 91.25492383905164, tolerance: 1e-12)

        let snapshots = ExpenditureEstimator.timeline(
            from: day(22), through: day(37), intake: Golden.backfilledIntake, weights: weights, calendar: utc
        )
        Golden.check(snapshots, against: Golden.editedSequence)
    }

    @Test("derived, not canonical: single-day evaluation equals the timeline, input order irrelevant")
    func recomputationIsStable() {
        let weights = weighIns(Golden.baseWeights)
        let timeline = ExpenditureEstimator.timeline(
            from: day(22), through: day(37), intake: Golden.baseIntake, weights: weights, calendar: utc
        )
        let shuffled = ExpenditureEstimator.timeline(
            from: day(22), through: day(37), intake: Golden.baseIntake.reversed(), weights: weights, calendar: utc
        )
        #expect(timeline == shuffled)
        for snapshot in timeline {
            let alone = ExpenditureEstimator.evaluate(
                on: snapshot.day, intake: Golden.baseIntake, weights: weights, calendar: utc
            )
            #expect(alone == snapshot.evaluation)
        }
    }
}

// MARK: - Acceptance #3: pause honesty

@Suite("Expenditure estimator: pause honesty (spec §3 acceptance #3)")
struct ExpenditurePauseTests {
    @Test("dropping from 14 to 13 complete days pauses; the last valid estimate stays with its as-of date")
    func dropToThirteen() throws {
        // Day 28's window is days 7–27: all 14 logged days. Day 29's window
        // is days 8–28: day 7 leaves, empty day 28 enters, 13 remain.
        let snapshots = ExpenditureEstimator.timeline(
            from: day(28), through: day(32), intake: fourteenLoggedDays, weights: flatWeights, calendar: utc
        )
        try #require(snapshots.count == 5)

        let tracking = snapshots[0]
        #expect(tracking.state == .tracking)
        let estimate = try #require(tracking.evaluation.estimate)
        // Σ(2070…2200 step 10) / 14 = 29 890 / 14 = 2135; Δtrend = 0.
        #expect(estimate.kcalPerDay == 2_135)
        #expect(estimate.meanIntakeKcal == 2_135)
        #expect(estimate.trendDeltaKg == 0)
        #expect(estimate.completeIntakeDays == 14)
        #expect(estimate.asOf == day(28))

        for paused in snapshots.dropFirst() {
            #expect(paused.state == .paused(.insufficientIntake))
            #expect(paused.evaluation == .paused(.insufficientIntake))
            // No new estimate values are emitted while paused…
            #expect(paused.evaluation.estimate == nil)
            // …and the display is exactly the last valid one, as-of day 28.
            #expect(paused.displayed == estimate)
            #expect(paused.displayed?.asOf == day(28))
        }
    }

    @Test("the fold keeps the previous display while paused and replaces it when tracking")
    func advanceFold() {
        let estimate = ExpenditureEstimate(
            kcalPerDay: 2_400, asOf: day(10), windowFirstDay: day(-11), windowLastDay: day(9),
            completeIntakeDays: 15, meanIntakeKcal: 2_300, trendDeltaKg: -0.3,
            energyDensityKcalPerKg: 7_700, formula: "FL-EB v1"
        )
        let first = ExpenditureSnapshot.advance(from: nil, day: day(10), evaluation: .tracking(estimate))
        let paused = ExpenditureSnapshot.advance(from: first, day: day(11), evaluation: .paused(.insufficientWeight))
        #expect(paused.displayed == estimate)
        #expect(paused.state == .paused(.insufficientWeight))
        let neverValid = ExpenditureSnapshot.advance(from: nil, day: day(11), evaluation: .paused(.noData))
        #expect(neverValid.displayed == nil)
    }

    @Test("sign: a trend fall of exactly 1 kg adds 7700/21 kcal/day")
    func trendFallRaisesExpenditure() throws {
        // Window for day 28 is days 7–27. Trend just before day 7 is 81.0;
        // trend at the end of day 27 is 80.0.
        let trend = handSetTrend([(morning(6), 81.0), (morning(10), 80.5), (morning(27), 80.0)])
        let estimate = try #require(evaluate(on: 28, fourteenLoggedDays, trend).estimate)
        #expect(estimate.trendDeltaKg == -1)
        // 2135 + 7700 / 21 = 2135 + 366.666… = 2501.666…
        expectClose(estimate.kcalPerDay, 2_135 + 7_700.0 / 21)
    }

    @Test("midnight boundaries: a weigh-in at today's midnight is outside, one at the window's first midnight is inside")
    func boundaries() throws {
        let trend = handSetTrend([
            (morning(5), 81.0),
            (day(7), 80.5),    // first instant of the window: inside, after the start trend
            (morning(27), 80.0),
            (day(28), 70.0)     // today's midnight: belongs to today, not the window
        ])
        let estimate = try #require(evaluate(on: 28, fourteenLoggedDays, trend).estimate)
        #expect(estimate.trendDeltaKg == -1)
        expectClose(estimate.kcalPerDay, 2_135 + 7_700.0 / 21)
    }

    @Test("only one weigh-in inside the window: insufficient weight")
    func oneWeighIn() {
        let trend = handSetTrend([(morning(0), 81.0), (morning(5), 80.5), (morning(20), 80.0)])
        #expect(evaluate(on: 28, fourteenLoggedDays, trend) == .paused(.insufficientWeight))
    }

    @Test("trend undefined just before the window: insufficient weight, never a shorter-span slope")
    func noStartTrend() {
        // Raw weigh-ins start inside the window (day 8); the trend is defined
        // by day 13, ≥2 weigh-ins inside, but there is no trend before day 7.
        let weights = weighIns((8...27).map { ($0, 80.0) })
        #expect(DayCompleteness.weight(window: day(7)...day(28).addingTimeInterval(-1), series: weights) == .complete)
        #expect(evaluate(on: 28, fourteenLoggedDays, weights) == .paused(.insufficientWeight))
    }

    @Test("reason precedence: noData, then insufficientIntake, then insufficientWeight")
    func precedence() {
        let empty = TrendSeries(smoothing: .standard, points: [])
        #expect(evaluate(on: 28, [], empty) == .paused(.noData))
        // Data entirely outside the window is still no data in it.
        #expect(evaluate(on: 45, fourteenLoggedDays, weighIns([(0, 80), (5, 80), (10, 80)])) == .paused(.noData))
        // Weigh-ins but no complete day: intake reason, not noData.
        #expect(evaluate(on: 28, [], flatWeights) == .paused(.insufficientIntake))
        // One complete day and no weights: intake reason.
        #expect(evaluate(on: 28, [logged(10, 2_000)], empty) == .paused(.insufficientIntake))
        // 13 complete days and no weights: intake reason wins.
        #expect(evaluate(on: 29, fourteenLoggedDays, empty) == .paused(.insufficientIntake))
        // 14 complete days and no weights: weight reason.
        #expect(evaluate(on: 28, fourteenLoggedDays, empty) == .paused(.insufficientWeight))
    }
}

// MARK: - Acceptance #8: reconstructed-day inclusion

@Suite("Expenditure estimator: reconstructed-day inclusion (spec §3 acceptance #8)")
struct ExpenditureReconstructedDayTests {
    @Test("an imported dietary-energy day counts and shifts expenditure by (X − mean) / 15")
    func shiftsByExpectedAmount() throws {
        let before = try #require(evaluate(on: 28, fourteenLoggedDays, flatWeights).estimate)
        #expect(before.kcalPerDay == 2_135)

        let after = try #require(
            evaluate(on: 28, fourteenLoggedDays + [reconstructed(25, 2_735)], flatWeights).estimate
        )
        // (29 890 + 2735) / 15 = 32 625 / 15 = 2175: a shift of exactly +40.
        #expect(after.completeIntakeDays == 15)
        #expect(after.meanIntakeKcal == 2_175)
        #expect(after.kcalPerDay == 2_175)
        #expect(after.kcalPerDay - before.kcalPerDay == 40)
    }

    @Test("13 logged days plus one imported day reach the gate")
    func flipsToTracking() throws {
        // Day 29's window (8–28) holds logged days 8–20: 13, Σ = 27 820.
        #expect(evaluate(on: 29, fourteenLoggedDays, flatWeights) == .paused(.insufficientIntake))
        let estimate = try #require(
            evaluate(on: 29, fourteenLoggedDays + [reconstructed(25, 2_504)], flatWeights).estimate
        )
        // (27 820 + 2504) / 14 = 30 324 / 14 = 2166.
        #expect(estimate.completeIntakeDays == 14)
        #expect(estimate.kcalPerDay == 2_166)
    }

    @Test("an imported day marked \"didn't track\" is excluded")
    func markedImportExcluded() {
        let intake = fourteenLoggedDays + [reconstructed(25, 2_504, markedDidNotTrack: true)]
        #expect(evaluate(on: 29, intake, flatWeights) == .paused(.insufficientIntake))
    }
}

// MARK: - Input handling

@Suite("Expenditure estimator: input handling")
struct ExpenditureInputTests {
    @Test("records on the same calendar day merge: kcal summed, marks win")
    func sameDayMerge() throws {
        // Day 20 split into two records of 1000 and 1200 (logged total 2200):
        // Σ = 29 890, n = 14, same as a single 2200 record.
        let split = fourteenLoggedDays.filter { $0.day != noon(20) }
            + [logged(20, 1_000, meals: 1), DayIntake(day: morning(20), intakeKcal: 1_200,
                                                     evidence: DayIntakeEvidence(loggedMealCount: 1))]
        let estimate = try #require(evaluate(on: 28, split, flatWeights).estimate)
        #expect(estimate.completeIntakeDays == 14)
        #expect(estimate.kcalPerDay == 2_135)

        // A second record marking day 20 "didn't track" removes the whole day.
        let marked = fourteenLoggedDays
            + [DayIntake(day: morning(20), intakeKcal: 0, evidence: DayIntakeEvidence(markedDidNotTrack: true))]
        #expect(evaluate(on: 28, marked, flatWeights) == .paused(.insufficientIntake))
    }

    @Test("a complete day with negative or non-finite kcal does not enter the mean", arguments: [-1.0, .nan, .infinity])
    func invalidIntakeExcluded(kcal: Double) {
        let intake = fourteenLoggedDays.filter { $0.day != noon(20) } + [logged(20, kcal)]
        #expect(evaluate(on: 28, intake, flatWeights) == .paused(.insufficientIntake))
    }

    @Test("a zero-kcal day with a logged meal still counts")
    func zeroKcalCounts() throws {
        // Replace day 20 (2200) with 0: Σ = 27 690, mean = 27 690 / 14.
        let intake = fourteenLoggedDays.filter { $0.day != noon(20) } + [logged(20, 0, meals: 1)]
        let estimate = try #require(evaluate(on: 28, intake, flatWeights).estimate)
        #expect(estimate.meanIntakeKcal == 27_690.0 / 14)
    }

    @Test("the window is 21 calendar days in the user's time zone, across a DST change")
    func calendarDaysAcrossDST() throws {
        var halifax = Calendar(identifier: .gregorian)
        halifax.timeZone = try #require(TimeZone(identifier: "America/Halifax"))
        func local(_ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int) throws -> Date {
            try #require(halifax.date(from: DateComponents(
                year: year, month: month, day: dayOfMonth, hour: hour
            )))
        }
        // Clocks fall back on 2026-11-01. Evaluate on 2026-11-15: the window
        // is 2026-10-25 through 2026-11-14, local days.
        let today = try local(2026, 11, 15, 9)
        let firstLunch = try local(2026, 10, 25, 12)
        let firstWeighIn = try local(2026, 10, 1, 7)
        let intake = (0..<21).compactMap { offset -> DayIntake? in
            halifax.date(byAdding: .day, value: offset, to: firstLunch).map {
                DayIntake(day: $0, intakeKcal: 2_100, evidence: DayIntakeEvidence(loggedMealCount: 1))
            }
        }
        let samples = (0..<40).compactMap { offset -> WeightSample? in
            halifax.date(byAdding: .day, value: offset, to: firstWeighIn).map {
                WeightSample(measuredAt: $0, weightKg: 75.0)
            }
        }
        try #require(intake.count == 21 && samples.count == 40)
        let weights = TrendWeight.series(samples: samples)
        let expectedAsOf = try local(2026, 11, 15, 0)
        let expectedFirst = try local(2026, 10, 25, 0)
        let expectedLast = try local(2026, 11, 14, 0)
        let estimate = try #require(ExpenditureEstimator.evaluate(
            on: today, intake: intake, weights: weights, calendar: halifax
        ).estimate)
        #expect(estimate.completeIntakeDays == 21)
        #expect(estimate.kcalPerDay == 2_100)
        #expect(estimate.asOf == expectedAsOf)
        #expect(estimate.windowFirstDay == expectedFirst)
        #expect(estimate.windowLastDay == expectedLast)
    }
}

// MARK: - Weight gate, both-ends reading (golden)

struct ExpenditureWeightGateGoldenTests {
    @Test("fresh user, complete logging and a weigh-in every morning from day 0: first .tracking day is day 27")
    func freshUserFirstTrackingDay() {
        // Why day 27 follows from the both-ends rule: the trend is undefined
        // until the sixth daily weigh-in (day 5, 07:00: at least 3 samples
        // and a 5-day span). Δtrend needs the trend just before the window's
        // first day, so that first day, today − 21, must start after day 5's
        // weigh-in: today − 21 ≥ 6, today ≥ 27. The end of the window is
        // never the binding side here. On day 26 the window starts at day 5
        // midnight, before any defined trend, so the estimator pauses with
        // .insufficientWeight although the window holds 21 complete intake
        // days (gate: 14) and the end-of-window weight check both pass.
        let intake = (0...40).map { logged($0, 2_000) }
        let weights = weighIns((0...40).map { ($0, 80.0) })

        #expect(evaluate(on: 26, intake, weights) == .paused(.insufficientWeight))
        guard case .tracking(let estimate) = evaluate(on: 27, intake, weights) else {
            Issue.record("expected .tracking on day 27")
            return
        }
        expectClose(estimate.kcalPerDay, 2_000)
        #expect(estimate.completeIntakeDays == 21)

        // Nothing earlier tracks either.
        for offset in 0...26 {
            if case .tracking = evaluate(on: offset, intake, weights) {
                Issue.record("day \(offset) must not be tracking")
            }
        }
    }
}
