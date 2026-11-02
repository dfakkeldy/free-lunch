// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One weigh-in from the corrected weight view (spec §1: HealthKit mirror
/// with Corrections already applied). This module never sees uncorrected
/// samples or Correction records; the caller resolves them first.
public struct WeightSample: Sendable, Hashable {
    public let measuredAt: Date
    public let weightKg: Double

    public init(measuredAt: Date, weightKg: Double) {
        self.measuredAt = measuredAt
        self.weightKg = weightKg
    }
}

/// The smoothing dial (spec §3, rendered by §6). One α drives both the
/// engine and the weight lane, so there is one trend truth.
public struct TrendSmoothing: Sendable, Hashable {
    /// Per-day smoothing factor.
    public let alpha: Double

    /// User-adjustable bounds for α, inclusive.
    public static let allowedAlphaRange: ClosedRange<Double> = 0.05...0.25

    /// The shipped default, α = 0.10/day.
    public static let standard = TrendSmoothing(validatedAlpha: 0.10)

    /// Returns nil for an α outside ``allowedAlphaRange`` (or NaN): an
    /// out-of-range dial is rejected, never silently clamped.
    public init?(alpha: Double) {
        guard Self.allowedAlphaRange.contains(alpha) else { return nil }
        self.alpha = alpha
    }

    private init(validatedAlpha: Double) {
        alpha = validatedAlpha
    }
}

/// One point of the trend series, aligned 1:1 with a sorted weigh-in.
public struct TrendPoint: Sendable, Hashable {
    public let measuredAt: Date
    /// The raw (corrected) weigh-in at this instant.
    public let weightKg: Double
    /// The smoothed trend after folding in this weigh-in, or nil while the
    /// trend is still undefined (fewer than 3 samples, or the samples so far
    /// span less than 5 days). Before that, lanes show raw points only.
    public let trendKg: Double?

    public init(measuredAt: Date, weightKg: Double, trendKg: Double?) {
        self.measuredAt = measuredAt
        self.weightKg = weightKg
        self.trendKg = trendKg
    }

    public var isTrendDefined: Bool { trendKg != nil }
}

/// Time-aware exponential smoothing of weight (spec §3 "Trend weight").
///
/// `trend(t) = trend(prev) + α_dt · (weight(t) − trend(prev))` with
/// `α_dt = 1 − (1 − α)^Δdays`, seeded with the first sample.
///
/// Decisions this implementation pins down:
/// - `Δdays` is continuous elapsed time (seconds / 86 400), not a count of
///   calendar days. Several weigh-ins on one day therefore all feed the
///   trend with a fractional α_dt, and a gap of three days decays as three
///   days. Two samples with the same timestamp give Δdays = 0, so α_dt = 0
///   and the later one has no effect on the trend.
/// - "Spanning ≥ 5 days" means the elapsed time from the first sample to the
///   current one is at least 5 × 86 400 seconds.
/// - Definedness is evaluated per point. The smoothing runs from the seed
///   regardless; only its exposure waits for the gate.
public enum TrendWeight {
    /// The trend needs at least this many samples before it is defined.
    public static let minimumSampleCount = 3
    /// …and they must span at least this many days.
    public static let minimumSpanDays: Double = 5

    static let secondsPerDay: Double = 86_400

    /// Gap-robust per-sample smoothing factor: `1 − (1 − α)^Δdays`.
    public static func alphaDt(alpha: Double, elapsedDays: Double) -> Double {
        1 - pow(1 - alpha, elapsedDays)
    }

    /// Smooths `samples` into a trend series. Input order does not matter:
    /// samples are sorted by time (ties broken by weight so the result does
    /// not depend on input order).
    public static func series(
        samples: [WeightSample],
        smoothing: TrendSmoothing = .standard
    ) -> TrendSeries {
        let sorted = samples.sorted {
            ($0.measuredAt, $0.weightKg) < ($1.measuredAt, $1.weightKg)
        }
        guard let seed = sorted.first else {
            return TrendSeries(smoothing: smoothing, points: [])
        }

        var points: [TrendPoint] = []
        points.reserveCapacity(sorted.count)
        var trend = seed.weightKg
        var previous = seed.measuredAt

        for (index, sample) in sorted.enumerated() {
            if index > 0 {
                let elapsedDays = sample.measuredAt.timeIntervalSince(previous) / secondsPerDay
                let factor = alphaDt(alpha: smoothing.alpha, elapsedDays: elapsedDays)
                trend += factor * (sample.weightKg - trend)
                previous = sample.measuredAt
            }
            let spanDays = sample.measuredAt.timeIntervalSince(seed.measuredAt) / secondsPerDay
            let defined = index + 1 >= minimumSampleCount && spanDays >= minimumSpanDays
            points.append(TrendPoint(
                measuredAt: sample.measuredAt,
                weightKg: sample.weightKg,
                trendKg: defined ? trend : nil
            ))
        }
        return TrendSeries(smoothing: smoothing, points: points)
    }
}

/// A computed trend series. Derived and recomputable, never canonical.
public struct TrendSeries: Sendable, Hashable {
    public let smoothing: TrendSmoothing
    /// One point per weigh-in, sorted by time.
    public let points: [TrendPoint]

    public init(smoothing: TrendSmoothing, points: [TrendPoint]) {
        self.smoothing = smoothing
        self.points = points
    }

    /// The most recent point at or before `date`, if any.
    public func latestPoint(asOf date: Date) -> TrendPoint? {
        points.last { $0.measuredAt <= date }
    }

    /// The trend as of `date`: the trend after the latest weigh-in at or
    /// before `date`. Between weigh-ins there is no new information, so the
    /// trend holds its last value; nothing is extrapolated. Nil before the
    /// first weigh-in or while the trend is still undefined.
    public func trend(asOf date: Date) -> Double? {
        latestPoint(asOf: date)?.trendKg
    }

    /// Whether the trend is defined as of `date`.
    public func isTrendDefined(asOf date: Date) -> Bool {
        trend(asOf: date) != nil
    }
}
