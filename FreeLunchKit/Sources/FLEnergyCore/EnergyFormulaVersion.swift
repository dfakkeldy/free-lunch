// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where a formula version came from (spec §1 FormulaVersion.origin). Mirrors
/// FLCore's `FormulaOrigin`; FLEnergyCore stays dependency-free, so the
/// persistence layer maps between the two.
public enum EnergyFormulaOrigin: Sendable, Hashable, Codable {
    /// A shipped builtin, with its identifier (for example "FL-EB v1").
    case builtin(String)
    case userEdited
    case imported
}

/// One version of the expenditure math (spec §3 "Versioning"). A
/// TargetPeriod pins the whole value, so history always renders with the
/// math it was adopted under.
///
/// Scope: the §4 expression workbench is not built yet, so every version
/// evaluates the `FL-EB v1` expression with its own parameters (ρ). A change
/// to the math is therefore a new version with a new name and parameters;
/// nothing about a version is edited in place.
public struct EnergyFormulaVersion: Sendable, Hashable, Codable {
    /// Display name, for example "FL-EB v1".
    public let name: String
    public let origin: EnergyFormulaOrigin
    /// The version's parameters. ρ is the only one this module evaluates;
    /// W and the 14-day gate are fixed by `FL-EB v1`.
    public let parameters: ExpenditureParameters

    public init(name: String, origin: EnergyFormulaOrigin, parameters: ExpenditureParameters) {
        self.name = name
        self.origin = origin
        self.parameters = parameters
    }

    /// The builtin `FL-EB v1`, ρ = 7700 kcal/kg.
    public static let builtinV1 = EnergyFormulaVersion(
        name: ExpenditureFormulaV1.identifier,
        origin: .builtin(ExpenditureFormulaV1.identifier),
        parameters: .standard
    )

    /// `FL-EB v1` written in the §4 expression language, for the persisted
    /// FormulaVersion's `definition`.
    public static let builtinV1Definition = "intake_mean - (trend_delta * rho / window_days)"

    /// Evaluates this version's math for `today`.
    public func evaluate(
        on today: Date,
        intake: [DayIntake],
        weights: TrendSeries,
        calendar: Calendar
    ) -> ExpenditureEvaluation {
        ExpenditureEstimator.evaluate(
            on: today, intake: intake, weights: weights, calendar: calendar, parameters: parameters
        )
    }
}

extension ExpenditureParameters: Codable {
    private enum CodingKeys: String, CodingKey {
        case energyDensityKcalPerKg
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rho = try container.decode(Double.self, forKey: .energyDensityKcalPerKg)
        guard let parameters = ExpenditureParameters(energyDensityKcalPerKg: rho) else {
            throw DecodingError.dataCorruptedError(
                forKey: .energyDensityKcalPerKg, in: container,
                debugDescription: "energy density must be finite and positive"
            )
        }
        self = parameters
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(energyDensityKcalPerKg, forKey: .energyDensityKcalPerKg)
    }
}

/// When each formula version became active. Activation is explicit and
/// forward-only (spec §3 "Versioning", locked): it applies from its day on
/// and never reaches back. The only retroactive path is
/// ``EnergyHistory/rerun(with:from:through:intake:weights:calendar:)``,
/// whose output is labeled reconstructed.
public struct FormulaActivationSchedule: Sendable, Hashable {
    public struct Activation: Sendable, Hashable, Codable {
        public let formula: EnergyFormulaVersion
        /// Start of the first calendar day the formula is active.
        public let effectiveFrom: Date
    }

    /// Activations in the order they happened; effective days never
    /// decrease.
    public private(set) var activations: [Activation]

    /// A schedule where `initial` has always been active.
    public init(initial: EnergyFormulaVersion = .builtinV1) {
        activations = [Activation(formula: initial, effectiveFrom: .distantPast)]
    }

    public enum ActivationError: Error, Sendable, Hashable {
        /// The requested day is before the latest activation's day.
        /// Activation never applies to the past.
        case retroactive(latestEffectiveFrom: Date)
    }

    /// The formula active on `day`'s calendar day. When several activations
    /// share a day, the latest one wins.
    public func formula(on day: Date, calendar: Calendar) -> EnergyFormulaVersion {
        let start = calendar.startOfDay(for: day)
        // activations[0] is effective from distantPast, so a match exists.
        return activations.last { $0.effectiveFrom <= start }?.formula ?? activations[0].formula
    }

    /// The formula active now (the latest activation).
    public var latest: EnergyFormulaVersion {
        activations[activations.count - 1].formula
    }

    /// Returns a schedule with `formula` active from `day`'s calendar day
    /// onward. Throws for a day before the latest activation.
    public func activating(
        _ formula: EnergyFormulaVersion,
        from day: Date,
        calendar: Calendar
    ) throws(ActivationError) -> FormulaActivationSchedule {
        let start = calendar.startOfDay(for: day)
        let latestStart = activations[activations.count - 1].effectiveFrom
        guard start >= latestStart else {
            throw .retroactive(latestEffectiveFrom: latestStart)
        }
        var next = self
        next.activations.append(Activation(formula: formula, effectiveFrom: start))
        return next
    }
}
