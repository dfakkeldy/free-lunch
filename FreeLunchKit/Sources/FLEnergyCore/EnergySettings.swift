// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The settings the energy engine reads (spec §3 and §6), as one value.
/// The day-level "didn't track" marks are not here: they are records of
/// days, not a setting.
///
/// The defaults are the spec's: α = 0.10/day, maintenance rate, suggest-only
/// adoption (spec §3: weekly auto-adopt is an opt-in), and the builtin
/// formula active from the start.
public struct EnergySettings: Sendable, Hashable {
    /// The trend smoothing dial, 0.05–0.25 (spec §3, §6).
    public var smoothing: TrendSmoothing
    /// Signed kg/week, loss negative (spec §3 "Calculated target").
    public var rateGoal: RateGoal
    public var adoptionMode: AdoptionMode
    /// Which formula version is active from which day (spec §3
    /// "Versioning").
    public var schedule: FormulaActivationSchedule

    public init(
        smoothing: TrendSmoothing = .standard,
        rateGoal: RateGoal = .maintenance,
        adoptionMode: AdoptionMode = .default,
        schedule: FormulaActivationSchedule = FormulaActivationSchedule()
    ) {
        self.smoothing = smoothing
        self.rateGoal = rateGoal
        self.adoptionMode = adoptionMode
        self.schedule = schedule
    }

    /// What a store with no saved settings reads as.
    public static let defaults = EnergySettings()
}
