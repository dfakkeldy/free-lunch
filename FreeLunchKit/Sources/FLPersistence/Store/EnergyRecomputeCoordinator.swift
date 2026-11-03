// SPDX-License-Identifier: GPL-3.0-or-later
// Runs the §3 recompute when, and only when, a trigger has fired (spec §3
// "Recompute"; spec §6 "Smoothing control": changing α recomputes
// everything).
//
// The inputs come from the store: stored meals, the corrected weight view
// smoothed with the persisted α, the persisted activation schedule and rate
// goal, and the persisted "didn't track" marks. The coordinator remembers the
// key of its last computation. After every settings write it rebuilds the
// key and diffs it against that one with `EnergyRecomputeReason.reasons`, so
// a write that changes no input (the same α again, a day marked twice) costs
// no recompute, and a write that changes one costs exactly one, however many
// reasons the diff reports.
//
// The re-adoption suggestion is the one part of a result that reads the
// target ledger, which is not an engine input and so not in the key. A
// refresh that finds the key unchanged still re-reads the open period, so an
// adoption (explicit or weekly) clears or moves the suggestion without
// running the engine again.
//
// The computation itself is injectable (`compute`). The default is
// `EnergyBinding.recompute`; a test passes a counting wrapper to see how
// many times the engine really ran.
import FLCore
import FLEnergyCore
import Foundation

extension EnergyBinding {
    /// The corrected weight view (spec §1) smoothed with `smoothing`: the one
    /// trend the engine and the weight lane share (spec §6 "one trend truth").
    public static func trendSeries(store: some WeightStore, smoothing: TrendSmoothing) throws -> TrendSeries {
        let samples = try store.correctedWeightView().map {
            WeightSample(measuredAt: $0.measuredAt, weightKg: $0.weightKg)
        }
        return TrendWeight.series(samples: samples, smoothing: smoothing)
    }

    /// The recompute key for `today` with every setting read from the store:
    /// α (through the weight series), the activation schedule, the rate goal
    /// and the "didn't track" marks. `weights` replaces the default series
    /// built from the store's corrected weight view.
    public static func key(
        store: some MealStore & WeightStore & EnergySettingsStore,
        today: Date,
        historyFrom: Date,
        calendar: Calendar,
        weights: ((TrendSmoothing) throws -> TrendSeries)? = nil
    ) throws -> EnergyRecomputeKey {
        let settings = try store.energySettings()
        let series = try weights.map { try $0(settings.smoothing) }
            ?? trendSeries(store: store, smoothing: settings.smoothing)
        return try key(
            store: store, today: today, historyFrom: historyFrom, weights: series,
            schedule: settings.schedule, rateGoal: settings.rateGoal, calendar: calendar,
            markedDidNotTrack: try store.didNotTrackDays(calendar: calendar)
        )
    }
}

/// Keeps the live energy series current against the persisted settings.
/// Phone store only, like the settings it reads.
@MainActor
public final class EnergyRecomputeCoordinator<Store: MealStore & TargetStore & WeightStore & EnergySettingsStore> {
    /// One computation from a key. The default is ``EnergyBinding/recompute(store:key:calendar:)``.
    public typealias Compute = (EnergyRecomputeKey) throws -> LiveEnergy

    private let store: Store
    private let calendar: Calendar
    private let weights: ((TrendSmoothing) throws -> TrendSeries)?
    private let compute: Compute
    private var today: Date
    private var historyFrom: Date

    /// The last computation, nil before the first ``refresh()``.
    public private(set) var latest: LiveEnergy?

    public init(
        store: Store,
        calendar: Calendar,
        today: Date,
        historyFrom: Date,
        weights: ((TrendSmoothing) throws -> TrendSeries)? = nil,
        compute: Compute? = nil
    ) {
        self.store = store
        self.calendar = calendar
        self.today = today
        self.historyFrom = historyFrom
        self.weights = weights
        self.compute = compute ?? { key in try EnergyBinding.recompute(store: store, key: key, calendar: calendar) }
    }

    /// Recomputes if an input changed since the last computation and
    /// otherwise returns it with the re-adoption suggestion re-read against
    /// the stored ledger. When the computation throws, the last result and
    /// its key stand, so the next call tries again.
    @discardableResult
    public func refresh() throws -> LiveEnergy {
        let key = try EnergyBinding.key(
            store: store, today: today, historyFrom: historyFrom, calendar: calendar, weights: weights
        )
        if let latest, EnergyRecomputeReason.reasons(from: latest.key, to: key).isEmpty {
            let suggestion = try latest.calculatedTarget.flatMap {
                try store.targetLedger().readoptionSuggestion(live: $0)
            }
            guard suggestion != latest.readoptionSuggestion else { return latest }
            let updated = LiveEnergy(
                key: latest.key,
                history: latest.history,
                evaluation: latest.evaluation,
                calculatedTarget: latest.calculatedTarget,
                readoptionSuggestion: suggestion
            )
            self.latest = updated
            return updated
        }
        let energy = try compute(key)
        latest = energy
        return energy
    }

    /// The first foreground of a new day, or a new range of history.
    @discardableResult
    public func advance(today: Date, historyFrom: Date) throws -> LiveEnergy {
        self.today = today
        self.historyFrom = historyFrom
        return try refresh()
    }

    // MARK: - Settings that move the series

    /// Spec §6 acceptance #3: α change cascades. Refused values (outside
    /// 0.05–0.25) throw before anything is stored or recomputed.
    @discardableResult
    public func setTrendAlpha(_ alpha: Double) throws -> LiveEnergy {
        try store.setTrendAlpha(alpha)
        return try refresh()
    }

    @discardableResult
    public func setRateGoal(kgPerWeek: Double) throws -> LiveEnergy {
        try store.setRateGoal(kgPerWeek: kgPerWeek)
        return try refresh()
    }

    /// Forward only: a `day` before the coordinator's today is refused
    /// (spec §3 "Versioning").
    @discardableResult
    public func activateFormula(_ formula: EnergyFormulaVersion, from day: Date) throws -> LiveEnergy {
        try store.activateFormula(formula, from: day, today: today, calendar: calendar)
        return try refresh()
    }

    /// Spec §7 "Didn't track today".
    @discardableResult
    public func markDidNotTrack(day: Date) throws -> LiveEnergy {
        try store.markDidNotTrack(day: day, calendar: calendar)
        return try refresh()
    }

    @discardableResult
    public func unmarkDidNotTrack(day: Date) throws -> LiveEnergy {
        try store.unmarkDidNotTrack(day: day, calendar: calendar)
        return try refresh()
    }
}
