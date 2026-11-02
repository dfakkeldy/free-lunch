// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLEnergyCore

// Expected values below were computed by hand and cross-checked with a
// throwaway script outside the repo; none are taken from this module's output.

/// An arbitrary synthetic origin; fixtures are offsets in whole or half days
/// of exactly 86 400 seconds, so no calendar or DST is involved.
private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func day(_ offset: Double) -> Date {
    origin.addingTimeInterval(offset * 86_400)
}

private func samples(_ pairs: [(Double, Double)]) -> [WeightSample] {
    pairs.map { WeightSample(measuredAt: day($0.0), weightKg: $0.1) }
}

private func smoothing(_ alpha: Double) throws -> TrendSmoothing {
    try #require(TrendSmoothing(alpha: alpha))
}

private func expectClose(
    _ actual: Double?,
    _ expected: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let actual else {
        Issue.record("expected \(expected), got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(abs(actual - expected) <= 1e-12, "\(actual) vs \(expected)", sourceLocation: sourceLocation)
}

@Suite("Trend weight: gap-robust smoothing factor (spec §3 acceptance #2)")
struct AlphaDtTests {
    @Test(
        "a 3-day gap gives α_dt = 1 − (1 − α)³ exactly",
        arguments: [
            (0.05, 0.1426250000000001),
            (0.10, 0.2709999999999999),
            (0.25, 0.578125)
        ]
    )
    func threeDayGap(alpha: Double, expected: Double) {
        let actual = TrendWeight.alphaDt(alpha: alpha, elapsedDays: 3)
        #expect(actual == expected)
        #expect(actual == 1 - (1 - alpha) * (1 - alpha) * (1 - alpha))
    }

    @Test("one day gives α, no elapsed time gives 0")
    func oneDayAndZero() {
        #expect(abs(TrendWeight.alphaDt(alpha: 0.10, elapsedDays: 1) - 0.10) <= 1e-15)
        #expect(TrendWeight.alphaDt(alpha: 0.10, elapsedDays: 0) == 0)
    }

    @Test("a half-day gap gets a fractional factor")
    func halfDay() {
        #expect(abs(TrendWeight.alphaDt(alpha: 0.10, elapsedDays: 0.5) - 0.05131670194948623) <= 1e-15)
    }
}

@Suite("Trend weight: smoothing series")
struct TrendSeriesTests {
    /// Days 0, 1, 2, then a 3-day gap to day 5, then day 6.
    let gapFixture = samples([(0, 100.0), (1, 99.0), (2, 99.5), (5, 98.0), (6, 98.4)])

    @Test("gap fixture at α = 0.10: three missed days decay as three days")
    func gapFixtureDefault() {
        let series = TrendWeight.series(samples: gapFixture)
        #expect(series.smoothing.alpha == 0.10)
        #expect(series.points.map(\.weightKg) == [100.0, 99.0, 99.5, 98.0, 98.4])
        // Undefined until ≥3 samples spanning ≥5 days: the first three span 2.
        #expect(series.points[0].trendKg == nil)
        #expect(series.points[1].trendKg == nil)
        #expect(series.points[2].trendKg == nil)
        // 99.86 + 0.271 × (98 − 99.86) = 99.35594
        expectClose(series.points[3].trendKg, 99.35594)
        // Treating the gap as one sample would have given 99.674.
        #expect(abs((series.points[3].trendKg ?? 0) - 99.674) > 0.3)
        // 99.35594 + 0.1 × (98.4 − 99.35594) = 99.260346
        expectClose(series.points[4].trendKg, 99.260346)
    }

    @Test("gap fixture at α = 0.25")
    func gapFixtureFast() throws {
        let series = TrendWeight.series(samples: gapFixture, smoothing: try smoothing(0.25))
        expectClose(series.points[3].trendKg, 98.7119140625)
        expectClose(series.points[4].trendKg, 98.633935546875)
    }

    @Test("every step a 3-day gap")
    func allThreeDayGaps() {
        let series = TrendWeight.series(samples: samples([(0, 100.0), (3, 97.0), (6, 97.0)]))
        // 100 → 99.187 (hidden) → 99.187 + 0.271 × (97 − 99.187)
        #expect(series.points[1].trendKg == nil)
        expectClose(series.points[2].trendKg, 98.594323)
    }

    @Test("seed is the first sample, not the first in input order")
    func unsortedInput() {
        let shuffled = [gapFixture[3], gapFixture[0], gapFixture[4], gapFixture[2], gapFixture[1]]
        #expect(TrendWeight.series(samples: shuffled) == TrendWeight.series(samples: gapFixture))
    }

    @Test("a same-instant duplicate does not move the trend but counts as a sample")
    func duplicateTimestamp() {
        let series = TrendWeight.series(samples: samples([(0, 104.0), (0, 100.0), (5, 99.0)]))
        // Seed 100 (ties broken by weight), 104 at Δ = 0 has α_dt = 0,
        // then 100 + (1 − 0.9⁵) × (99 − 100) = 99.59049.
        expectClose(series.points[2].trendKg, 99.59049)
    }

    @Test("no samples gives an empty series")
    func empty() {
        let series = TrendWeight.series(samples: [])
        #expect(series.points.isEmpty)
        #expect(series.trend(asOf: day(100)) == nil)
    }
}

@Suite("Trend weight: definedness gate (spec §3 acceptance #2)")
struct TrendGateTests {
    @Test("3 samples spanning exactly 5 days: defined at the third")
    func exactlyFiveDays() {
        let series = TrendWeight.series(samples: samples([(0, 80.0), (2.5, 79.0), (5, 79.5)]))
        #expect(series.points[0].trendKg == nil)
        #expect(series.points[1].trendKg == nil)
        expectClose(series.points[2].trendKg, 79.70627326428955)
    }

    @Test("3 samples spanning one second short of 5 days: undefined")
    func justUnderFiveDays() {
        let raw = samples([(0, 80.0), (2, 79.0)])
            + [WeightSample(measuredAt: day(5).addingTimeInterval(-1), weightKg: 79.5)]
        let series = TrendWeight.series(samples: raw)
        #expect(series.points.allSatisfy { !$0.isTrendDefined })
    }

    @Test("4 samples spanning 4.5 days: undefined")
    func manySamplesShortSpan() {
        let series = TrendWeight.series(samples: samples([(0, 80.0), (2, 79.0), (4, 79.5), (4.5, 79.2)]))
        #expect(series.points.allSatisfy { !$0.isTrendDefined })
    }

    @Test("2 samples spanning 10 days: undefined until a third arrives")
    func twoSamplesLongSpan() {
        let two = TrendWeight.series(samples: samples([(0, 80.0), (10, 82.0)]))
        #expect(two.points.allSatisfy { !$0.isTrendDefined })

        let three = TrendWeight.series(samples: samples([(0, 80.0), (10, 82.0), (11, 81.0)]))
        #expect(three.points[1].trendKg == nil)
        // 80 + (1 − 0.9¹⁰) × 2 = 81.3026431198, then + 0.1 × (81 − 81.3026431198)
        expectClose(three.points[2].trendKg, 81.27237880781999)
    }

    @Test("trend(asOf:) holds the latest point's value and never extrapolates")
    func trendAsOf() {
        let series = TrendWeight.series(samples: samples([(0, 100.0), (1, 99.0), (2, 99.5), (5, 98.0), (6, 98.4)]))
        #expect(series.trend(asOf: day(-1)) == nil)
        #expect(series.trend(asOf: day(0)) == nil)
        #expect(series.trend(asOf: day(4.9)) == nil)
        #expect(!series.isTrendDefined(asOf: day(4.9)))
        expectClose(series.trend(asOf: day(5)), 99.35594)
        expectClose(series.trend(asOf: day(5.99)), 99.35594)
        expectClose(series.trend(asOf: day(40)), 99.260346)
        #expect(series.isTrendDefined(asOf: day(40)))
    }
}

@Suite("Trend weight: smoothing dial")
struct TrendSmoothingTests {
    @Test("default α is 0.10/day")
    func standard() {
        #expect(TrendSmoothing.standard.alpha == 0.10)
    }

    @Test("α is accepted inside 0.05…0.25 inclusive", arguments: [0.05, 0.10, 0.17, 0.25])
    func accepted(alpha: Double) {
        #expect(TrendSmoothing(alpha: alpha)?.alpha == alpha)
    }

    @Test("α outside 0.05…0.25 is rejected", arguments: [0.0, 0.0499, 0.2501, 1.0, -0.1, Double.nan])
    func rejected(alpha: Double) {
        #expect(TrendSmoothing(alpha: alpha) == nil)
    }
}

@Suite("Trend weight: input hardening")
struct TrendHardeningTests {
    @Test(
        "a non-finite weigh-in is dropped and cannot poison the trend",
        arguments: [Double.nan, Double.infinity, -Double.infinity]
    )
    func nonFiniteDropped(bad: Double) {
        let clean = samples([(0, 100.0), (1, 99.0), (2, 99.5), (5, 98.0), (6, 98.4)])
        let dirty = clean + [WeightSample(measuredAt: day(3), weightKg: bad)]
        let series = TrendWeight.series(samples: dirty)
        #expect(series.points.count == 5)
        #expect(series.points.allSatisfy { $0.weightKg.isFinite })
        // Same values as the clean gap fixture above.
        expectClose(series.points[3].trendKg, 99.35594)
        expectClose(series.points[4].trendKg, 99.260346)
        expectClose(series.trend(asOf: day(40)), 99.260346)
    }

    @Test("a non-finite weigh-in does not count toward the 3-sample gate")
    func nonFiniteNotCounted() {
        let raw = samples([(0, 80.0), (5, 79.5)]) + [WeightSample(measuredAt: day(2.5), weightKg: .nan)]
        let series = TrendWeight.series(samples: raw)
        #expect(series.points.count == 2)
        #expect(!series.isTrendDefined(asOf: day(5)))
    }

    @Test("a hand-built series in any order answers as-of queries in time order")
    func unsortedPublicInit() {
        let early = TrendPoint(measuredAt: day(0), weightKg: 80.0, trendKg: nil)
        let middle = TrendPoint(measuredAt: day(5), weightKg: 79.0, trendKg: 79.5)
        let late = TrendPoint(measuredAt: day(9), weightKg: 78.0, trendKg: 79.0)
        let series = TrendSeries(smoothing: .standard, points: [late, early, middle])
        #expect(series.points == [early, middle, late])
        #expect(series.latestPoint(asOf: day(6)) == middle)
        #expect(series.trend(asOf: day(6)) == 79.5)
        #expect(series.trend(asOf: day(1)) == nil)
        #expect(series.trend(asOf: day(9)) == 79.0)
    }

    @Test("a hand-built series already in order is kept as given")
    func sortedPublicInitUnchanged() {
        let first = TrendPoint(measuredAt: day(0), weightKg: 81.0, trendKg: nil)
        let second = TrendPoint(measuredAt: day(0), weightKg: 80.0, trendKg: 80.5)
        let series = TrendSeries(smoothing: .standard, points: [first, second])
        #expect(series.points == [first, second])
    }
}
