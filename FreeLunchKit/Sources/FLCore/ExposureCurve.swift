// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — exposure curve (spec §5 Exposure curve, acceptance #2, #3, #6)
//
// A population estimate from the profile's half-life and tmax, never a
// measured level. The output is unit-free: percent of the steady-state peak.
// No absolute level (mg, ng/mL or any concentration) leaves this file.
//
// Model:
// - One-compartment Bateman curve per logged shot, scaled by its dose, and
//   summed (superposition). A shot contributes nothing before its takenAt.
// - ke = ln 2 / halfLifeHours.
// - ka > ke is solved so a single dose peaks at tmaxHours:
//   ln(ka / ke) / (ka - ke) = tmax. With x = ka / ke - 1 this reads
//   log1p(x) / x = ke·tmax, whose left side falls strictly from 1 (x → 0)
//   to 0 (x → ∞). A root exists only when 0 < tmax < 1 / ke
//   (= halfLifeHours / ln 2). x is found by bisection: the upper bracket
//   doubles from 1 until it passes the root, then the bracket halves until
//   the midpoint no longer moves in Double. Same inputs, same ka. A root
//   with x ≤ 1e-9 is rejected: ka sits so close to ke that the difference
//   of exponentials loses its precision, down to a flat zero at the bound.
// - The Bateman constant ka / (ka - ke) multiplies the curve and the
//   reference alike, so it is left out.
//
// Reference (100%):
// - The peak a never-miss schedule reaches at steady state, at the latest
//   logged shot's dose (ties broken by id, as for dose periods) and the
//   profile's intervalDays. It is recomputed from the shots and profile on
//   every construction, so a new dose or interval moves it.
// - Closed form for interval T: a unit-dose train is
//   e^(−ke·t) / (1 − e^(−ke·T)) − e^(−ka·t) / (1 − e^(−ka·T)) for t in
//   [0, T) after a shot, peaking at
//   t* = ln[ka·(1 − e^(−ke·T)) / (ke·(1 − e^(−ka·T)))] / (ka − ke),
//   which always lies inside (0, T) and before the single-dose tmax.
//
// Gaps are honest: only logged shots enter the sum, so a missed dose shows
// the decay trough. Nothing is interpolated or projected, and values are not
// capped (a shorter spacing than the interval can exceed 100%).
//
// Only shots whose medicationID matches the profile are used.
import Foundation

public enum ExposureCurveError: Error, Sendable, Hashable {
    /// No shot for this profile was logged.
    case noShots
    /// halfLifeHours is not a positive finite number.
    case invalidHalfLife
    /// tmaxHours is not in (0, halfLifeHours / ln 2), so no single-dose
    /// curve with ka > ke peaks there. A tmax so close to the upper bound
    /// that ka would differ from ke by less than one part in 10^9 counts as
    /// the bound.
    case invalidTmax
    /// intervalDays is not positive.
    case invalidInterval
    /// A dose is negative or not finite, or the latest dose is zero.
    case invalidDose
}

/// One point on the curve. `percentOfSteadyState` is a percent, unit-free:
/// 100 is the steady-state peak of the reference regimen.
public struct ExposureSample: Sendable, Hashable {
    public let date: Date
    public let percentOfSteadyState: Double
}

public struct ExposureCurve: Sendable {
    /// The never-miss regimen whose steady-state peak is 100%.
    public struct ReferenceRegimen: Sendable, Hashable {
        /// Dose of the latest logged shot, in the shots' own milligrams.
        public let doseMg: Double
        public let intervalDays: Int
        /// Hours after each shot at which the steady-state train peaks.
        public let peakOffsetHours: Double
    }

    /// ke, per hour.
    public let eliminationRatePerHour: Double
    /// ka, per hour.
    public let absorptionRatePerHour: Double
    public let reference: ReferenceRegimen

    /// Logged shots as (takenAt, dose), time ordered.
    private let shots: [(takenAt: Date, doseMg: Double)]
    /// Dose-weighted steady-state peak of the reference, same scale as the
    /// internal sum. Never exposed.
    private let referencePeak: Double

    static let secondsPerHour: Double = 3_600
    /// Smallest accepted ka / ke - 1. Below it ka cannot be told from ke.
    static let minimumRateGap: Double = 1e-9

    public init(shots: [ShotEventData], profile: MedicationProfileData) throws(ExposureCurveError) {
        let halfLife = profile.halfLifeHours
        guard halfLife.isFinite, halfLife > 0 else { throw .invalidHalfLife }
        guard profile.intervalDays > 0 else { throw .invalidInterval }
        let ke = M_LN2 / halfLife
        guard let ka = Self.absorptionRate(eliminationRate: ke, tmaxHours: profile.tmaxHours) else {
            throw .invalidTmax
        }

        let ordered = shots
            .filter { $0.medicationID == profile.id }
            .sorted { lhs, rhs in
                if lhs.takenAt != rhs.takenAt { return lhs.takenAt < rhs.takenAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard let latest = ordered.last else { throw .noShots }
        for shot in ordered where !(shot.doseMg.isFinite && shot.doseMg >= 0) {
            throw .invalidDose
        }
        guard latest.doseMg > 0 else { throw .invalidDose }

        let intervalHours = Double(profile.intervalDays) * 24
        let unit = Self.steadyStatePeak(ke: ke, ka: ka, intervalHours: intervalHours)

        self.eliminationRatePerHour = ke
        self.absorptionRatePerHour = ka
        self.reference = ReferenceRegimen(
            doseMg: latest.doseMg,
            intervalDays: profile.intervalDays,
            peakOffsetHours: unit.offsetHours
        )
        self.shots = ordered.map { ($0.takenAt, $0.doseMg) }
        self.referencePeak = latest.doseMg * unit.peak
    }

    /// Percent of the steady-state peak at `date`. 0 before the first shot.
    public func percentOfSteadyState(at date: Date) -> Double {
        var sum = 0.0
        for shot in shots {
            let hours = date.timeIntervalSince(shot.takenAt) / Self.secondsPerHour
            guard hours > 0 else { break }
            sum += shot.doseMg * Self.unitShot(ke: eliminationRatePerHour, ka: absorptionRatePerHour, hours: hours)
        }
        return 100 * sum / referencePeak
    }

    /// The curve at each date, in the order given.
    public func samples(at dates: [Date]) -> [ExposureSample] {
        dates.map { ExposureSample(date: $0, percentOfSteadyState: percentOfSteadyState(at: $0)) }
    }

    // MARK: - Math

    /// Single unit-dose shape without the Bateman constant.
    static func unitShot(ke: Double, ka: Double, hours: Double) -> Double {
        guard hours > 0 else { return 0 }
        return exp(-ke * hours) - exp(-ka * hours)
    }

    /// ka > ke such that ln(ka / ke) / (ka - ke) = tmaxHours, or nil when no
    /// such ka exists. See the header for the method.
    static func absorptionRate(eliminationRate ke: Double, tmaxHours: Double) -> Double? {
        guard ke.isFinite, ke > 0, tmaxHours.isFinite, tmaxHours > 0 else { return nil }
        let target = ke * tmaxHours
        guard target < 1 else { return nil }

        // h(x) = log1p(x) / x is strictly decreasing on (0, ∞).
        func h(_ x: Double) -> Double { log1p(x) / x }

        var lower = 0.0
        var upper = 1.0
        while h(upper) > target {
            lower = upper
            upper *= 2
            guard upper.isFinite else { return nil }
        }
        while true {
            let mid = lower + (upper - lower) / 2
            guard mid > lower, mid < upper else { break }
            if h(mid) > target { lower = mid } else { upper = mid }
        }
        let x = lower + (upper - lower) / 2
        // A tmax within rounding of the bound leaves ka a few ulps above ke,
        // and the curve cancels to nothing. Treat it as the bound itself.
        guard x > minimumRateGap else { return nil }
        let ka = ke * (1 + x)
        return ka.isFinite && ka > ke ? ka : nil
    }

    /// Steady-state peak of a unit-dose never-miss train, closed form.
    static func steadyStatePeak(ke: Double, ka: Double, intervalHours: Double) -> (offsetHours: Double, peak: Double) {
        let keRetained = -expm1(-ke * intervalHours)
        let kaRetained = -expm1(-ka * intervalHours)
        var offset = log((ka * keRetained) / (ke * kaRetained)) / (ka - ke)
        offset = min(max(offset, 0), intervalHours)
        let peak = exp(-ke * offset) / keRetained - exp(-ka * offset) / kaRetained
        return (offset, peak)
    }
}
