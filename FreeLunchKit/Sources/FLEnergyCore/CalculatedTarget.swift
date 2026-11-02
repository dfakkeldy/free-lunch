// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The user's signed rate goal in kg per week (spec §3 "Calculated target").
/// Loss is negative, gain positive, zero is maintenance. Storage is always
/// kg/week; lb/week is a display concern.
public struct RateGoal: Sendable, Hashable, Codable {
    public let kgPerWeek: Double

    /// Maintenance: 0 kg/week.
    public static let maintenance = RateGoal(validatedKgPerWeek: 0)

    /// Returns nil for a non-finite rate. Any finite rate is accepted: the
    /// rails warn, they never block (decision 2026-08-01).
    public init?(kgPerWeek: Double) {
        guard kgPerWeek.isFinite else { return nil }
        self.kgPerWeek = kgPerWeek
    }

    private init(validatedKgPerWeek: Double) {
        kgPerWeek = validatedKgPerWeek
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Double.self)
        guard value.isFinite else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "rate goal must be finite")
        }
        kgPerWeek = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kgPerWeek)
    }
}

/// A safety-rail warning (spec §3). Warnings are shown; they never block a
/// save or an adoption (adult-autonomy doctrine).
public enum TargetWarning: String, Sendable, Hashable, Codable, CaseIterable {
    /// The target is below ``TargetRails/minimumTargetKcal``.
    case targetBelowFloor
    /// |rate goal| is above ``TargetRails/maximumRateKgPerWeek``.
    case rateAboveLimit
}

/// The warn-only safety rails (spec §3, decision 2026-08-01). Both bounds
/// are strict: exactly 1200 kcal and exactly 1.0 kg/week do not warn.
public enum TargetRails {
    /// Warn when a target is below this, kcal/day.
    public static let minimumTargetKcal: Double = 1_200
    /// Warn when |rate goal| is above this, kg/week.
    public static let maximumRateKgPerWeek: Double = 1.0

    /// The warnings for a target value and the rate goal behind it.
    public static func warnings(targetKcal: Double, rateGoal: RateGoal) -> Set<TargetWarning> {
        var warnings: Set<TargetWarning> = []
        if targetKcal < minimumTargetKcal {
            warnings.insert(.targetBelowFloor)
        }
        if abs(rateGoal.kgPerWeek) > maximumRateKgPerWeek {
            warnings.insert(.rateAboveLimit)
        }
        return warnings
    }
}

/// The live calculated target (spec §3):
///
/// ```
/// calculatedTarget = expenditure + rateGoal_kg_per_week × ρ / 7
/// ```
///
/// Derived and recomputable on every recalculation. It is never the user's
/// number: only an explicit adoption turns it into an
/// ``AdoptedTargetPeriod``.
public struct CalculatedTarget: Sendable, Hashable {
    /// The expenditure the target was built from, kcal/day.
    public let expenditureKcal: Double
    public let rateGoal: RateGoal
    /// ρ, kcal/kg. Taken from the expenditure estimate so the rate term and
    /// the expenditure use the same energy density.
    public let energyDensityKcalPerKg: Double
    /// rateGoal × ρ / 7, kcal/day (negative for loss).
    public let rateAdjustmentKcal: Double
    /// expenditure + rate adjustment, kcal/day.
    public let kcalPerDay: Double
    /// Rail warnings for ``kcalPerDay`` and ``rateGoal``.
    public let warnings: Set<TargetWarning>

    /// Builds the target from an expenditure value and ρ.
    public init(expenditureKcal: Double, rateGoal: RateGoal, parameters: ExpenditureParameters = .standard) {
        let rho = parameters.energyDensityKcalPerKg
        let adjustment = rateGoal.kgPerWeek * rho / 7
        let target = expenditureKcal + adjustment
        self.expenditureKcal = expenditureKcal
        self.rateGoal = rateGoal
        energyDensityKcalPerKg = rho
        rateAdjustmentKcal = adjustment
        kcalPerDay = target
        warnings = TargetRails.warnings(targetKcal: target, rateGoal: rateGoal)
    }

    /// Builds the target from a valid expenditure estimate, using the ρ that
    /// produced the estimate.
    public init(estimate: ExpenditureEstimate, rateGoal: RateGoal) {
        // The estimate's ρ was validated when its parameters were built.
        let parameters = ExpenditureParameters(energyDensityKcalPerKg: estimate.energyDensityKcalPerKg)
            ?? .standard
        self.init(expenditureKcal: estimate.kcalPerDay, rateGoal: rateGoal, parameters: parameters)
    }
}
