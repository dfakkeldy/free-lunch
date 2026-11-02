// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The macro targets a TargetPeriod pins (spec §3 "Adopted target"): protein
/// in g/day and a fat floor as a percentage of the day's target. Carbs are
/// the remainder and are derived, not stored.
public struct MacroTargets: Sendable, Hashable, Codable {
    /// Suggested protein per kg of current trend weight, g/kg/day.
    public static let suggestedProteinGPerKg: Double = 1.6
    /// Default fat floor, percent of the energy target.
    public static let defaultFatFloorPct: Double = 20

    /// Energy per gram, kcal/g (Atwater general factors).
    public static let proteinKcalPerG: Double = 4
    public static let carbsKcalPerG: Double = 4
    public static let fatKcalPerG: Double = 9

    /// Protein target, g/day.
    public let proteinTargetG: Double
    /// Fat floor, percent of the energy target (0–100).
    public let fatFloorPct: Double

    /// Returns nil unless protein is finite and ≥ 0 and the fat floor is a
    /// percentage in 0...100.
    public init?(proteinTargetG: Double, fatFloorPct: Double = MacroTargets.defaultFatFloorPct) {
        guard proteinTargetG.isFinite, proteinTargetG >= 0,
              fatFloorPct.isFinite, (0...100).contains(fatFloorPct)
        else { return nil }
        self.proteinTargetG = proteinTargetG
        self.fatFloorPct = fatFloorPct
    }

    /// The suggestion: protein = 1.6 g × current trend kg, fat floor 20%.
    /// Nil while the trend is undefined (or not a positive finite weight):
    /// a protein number is never imputed from nothing.
    public static func suggested(trendKg: Double?) -> MacroTargets? {
        guard let trendKg, trendKg.isFinite, trendKg > 0 else { return nil }
        return MacroTargets(proteinTargetG: suggestedProteinGPerKg * trendKg)
    }

    /// The macro split for an energy target. Carbs take whatever energy is
    /// left after protein and the fat floor. When protein plus the fat floor
    /// already exceed the target, carbs are zero and the excess is reported
    /// in ``MacroBreakdown/overCommittedKcal`` rather than hidden.
    public func breakdown(targetKcal: Double) -> MacroBreakdown {
        let proteinKcal = proteinTargetG * Self.proteinKcalPerG
        let fatFloorKcal = targetKcal * fatFloorPct / 100
        let remainder = targetKcal - proteinKcal - fatFloorKcal
        let carbsKcal = max(0, remainder)
        return MacroBreakdown(
            targetKcal: targetKcal,
            proteinG: proteinTargetG,
            proteinKcal: proteinKcal,
            fatFloorG: fatFloorKcal / Self.fatKcalPerG,
            fatFloorKcal: fatFloorKcal,
            carbsG: carbsKcal / Self.carbsKcalPerG,
            carbsKcal: carbsKcal,
            overCommittedKcal: max(0, -remainder)
        )
    }
}

/// Grams and kcal per macro for one energy target. What the remaining-macros
/// surfaces (spec §2) read.
public struct MacroBreakdown: Sendable, Hashable {
    public let targetKcal: Double
    public let proteinG: Double
    public let proteinKcal: Double
    public let fatFloorG: Double
    public let fatFloorKcal: Double
    public let carbsG: Double
    public let carbsKcal: Double
    /// kcal by which protein plus the fat floor exceed the target; 0 when
    /// they fit.
    public let overCommittedKcal: Double
}
