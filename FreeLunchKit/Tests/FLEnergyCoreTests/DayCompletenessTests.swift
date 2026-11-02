// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLEnergyCore

private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func day(_ offset: Double) -> Date {
    origin.addingTimeInterval(offset * 86_400)
}

private func series(_ days: [Double]) -> TrendSeries {
    TrendWeight.series(samples: days.map { WeightSample(measuredAt: day($0), weightKg: 90.0) })
}

@Suite("Day completeness: intake (spec §3)")
struct IntakeCompletenessTests {
    @Test(
        "intake-complete iff (logged meal or reconstructed day) and not marked",
        arguments: [
            (DayIntakeEvidence(), IntakeCompleteness.incomplete(.nothingLogged)),
            (DayIntakeEvidence(loggedMealCount: 1), .complete),
            (DayIntakeEvidence(loggedMealCount: 4), .complete),
            (DayIntakeEvidence(hasReconstructedDietaryEnergy: true), .complete),
            (DayIntakeEvidence(loggedMealCount: 2, hasReconstructedDietaryEnergy: true), .complete),
            (DayIntakeEvidence(markedDidNotTrack: true), .incomplete(.markedDidNotTrack)),
            (DayIntakeEvidence(loggedMealCount: 2, markedDidNotTrack: true), .incomplete(.markedDidNotTrack)),
            (
                DayIntakeEvidence(hasReconstructedDietaryEnergy: true, markedDidNotTrack: true),
                .incomplete(.markedDidNotTrack)
            )
        ]
    )
    func truthTable(evidence: DayIntakeEvidence, expected: IntakeCompleteness) {
        let state = DayCompleteness.intake(evidence)
        #expect(state == expected)
        #expect(state.isComplete == (expected == .complete))
    }
}

@Suite("Day completeness: weight window (spec §3)")
struct WeightCompletenessTests {
    /// A 21-day window from day 10 to day 30, both instants inclusive.
    let window = day(10)...day(30)

    @Test("trend defined and two weigh-ins on the window bounds: complete")
    func complete() {
        let state = DayCompleteness.weight(window: window, series: series([0, 3, 6, 10, 30]))
        #expect(state == .complete)
        #expect(state.isComplete)
    }

    @Test("trend defined but one weigh-in inside: too few weigh-ins")
    func oneWeighIn() {
        let state = DayCompleteness.weight(window: window, series: series([0, 3, 6, 20]))
        #expect(state == .incomplete(.tooFewWeighIns))
    }

    @Test("a weigh-in one second past the window's end does not count")
    func justOutside() {
        let raw = [0.0, 3, 6, 20].map { WeightSample(measuredAt: day($0), weightKg: 90.0) }
            + [WeightSample(measuredAt: day(30).addingTimeInterval(1), weightKg: 90.0)]
        let state = DayCompleteness.weight(window: window, series: TrendWeight.series(samples: raw))
        #expect(state == .incomplete(.tooFewWeighIns))
    }

    @Test("two weigh-ins inside but only two samples in total: trend undefined")
    func twoSamplesOnly() {
        let state = DayCompleteness.weight(window: window, series: series([10, 30]))
        #expect(state == .incomplete(.trendUndefined))
    }

    @Test("trend becomes defined only after the window ends: trend undefined")
    func definedTooLate() {
        let early = day(0)...day(4)
        let state = DayCompleteness.weight(window: early, series: series([0, 2, 4, 8]))
        #expect(state == .incomplete(.trendUndefined))
    }

    @Test("both conditions failing reports trend undefined")
    func bothFail() {
        #expect(DayCompleteness.weight(window: window, series: series([0])) == .incomplete(.trendUndefined))
        #expect(DayCompleteness.weight(window: window, series: series([])) == .incomplete(.trendUndefined))
    }
}
