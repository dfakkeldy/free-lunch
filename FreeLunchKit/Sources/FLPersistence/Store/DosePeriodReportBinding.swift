// SPDX-License-Identifier: GPL-3.0-or-later
// Dose-period reports bound to the §3 trend (spec §5).
//
// FLCore derives the periods and counts but has no trend model, and
// FLEnergyCore (which owns the trend) must not see FLCore. This target is
// the one that imports both, so the binding lives here: the period's start
// and end instants are looked up on a `TrendSeries`.
import FLCore
import FLEnergyCore
import Foundation

extension DosePeriodReports {
    /// Reports with the trend change read from `trend`.
    ///
    /// A boundary's trend is `trend.trend(asOf:)`: the value after the
    /// latest weigh-in at or before that instant, held between weigh-ins and
    /// never extrapolated. A weigh-in stamped exactly at a boundary is
    /// therefore included, and a boundary with none that day carries the
    /// previous trend forward. Where no trend is defined yet (fewer than 3
    /// weigh-ins spanning 5 days, or none before the boundary) the period's
    /// change and weekly rate are nil.
    public static func reports(
        shots: [ShotEventData],
        profiles: [MedicationProfileData],
        meals: [MealEntryData],
        sideEffects: [SideEffectEntryData],
        asOf: Date,
        trend: TrendSeries
    ) -> [DosePeriodReport] {
        reports(
            shots: shots,
            profiles: profiles,
            meals: meals,
            sideEffects: sideEffects,
            asOf: asOf,
            trendKg: { trend.trend(asOf: $0) }
        )
    }
}
