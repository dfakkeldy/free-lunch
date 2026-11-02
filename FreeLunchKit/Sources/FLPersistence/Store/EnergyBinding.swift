// SPDX-License-Identifier: GPL-3.0-or-later
// FLEnergyCore bound to the store: the engine's inputs read from stored
// meals, the live series and calculated target recomputed from them, and
// the triggers that say when to recompute (spec §3).
//
// Everything here is derived and recomputable, never canonical (spec §3
// "Recompute"). Nothing in this file writes to the store: a recomputation
// reads meals and the target ledger and returns values, so a backfill edit
// moves expenditure and the calculated target and cannot reach an adopted
// TargetPeriod (spec §3 acceptance #4).
//
// Inputs this module does not own are passed in: the weight trend (the
// weight lane builds it from the corrected weight view with the user's α),
// the formula activation schedule and rate goal (settings), and the days
// the user marked "didn't track" (spec §1 has no entity for the mark yet).
import FLCore
import FLEnergyCore
import Foundation

extension MealStore {
    /// The engine's intake for each calendar day from `first` through `last`
    /// (inclusive) that has a logged meal or a "didn't track" mark, oldest
    /// first (spec §3 "Day completeness").
    ///
    /// A day's kcal is the sum of its logged meals' item snapshots, by the
    /// calendar day of `loggedAt`. Native meals count as logged MealEntries;
    /// HealthKit-imported meals are the reconstructed dietary-energy days of
    /// spec §10. Drafts never count.
    ///
    /// Double-count boundary (spec §10): a day with at least one native
    /// logged meal uses native intake only and its imported kcal are
    /// ignored; a day with no native meal uses the reconstruction. A day is
    /// never both.
    public func dayIntakes(
        from first: Date,
        through last: Date,
        calendar: Calendar,
        markedDidNotTrack: Set<Date> = []
    ) throws -> [DayIntake] {
        let start = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last)
        guard start <= lastDay,
              let endRaw = calendar.date(byAdding: .day, value: 1, to: lastDay)
        else { return [] }
        let end = calendar.startOfDay(for: endRaw)

        var days: [Date: IntakeDayTally] = [:]
        for meal in try loggedMeals(in: DateInterval(start: start, end: end)) {
            guard let loggedAt = meal.loggedAt else { continue }
            let key = calendar.startOfDay(for: loggedAt)
            var day = days[key] ?? IntakeDayTally()
            let kcal = meal.items.reduce(0) { $0 + $1.nutrition.kcal }
            if meal.source == .healthKitImport {
                day.importedKcal += kcal
                day.hasImport = true
            } else {
                day.nativeKcal += kcal
                day.nativeMeals += 1
            }
            days[key] = day
        }
        for mark in markedDidNotTrack {
            let key = calendar.startOfDay(for: mark)
            guard key >= start, key < end else { continue }
            days[key, default: IntakeDayTally()].marked = true
        }
        return days.keys.sorted().map { key in
            let day = days[key]!
            let native = day.nativeMeals > 0
            return DayIntake(
                day: key,
                intakeKcal: native ? day.nativeKcal : day.importedKcal,
                evidence: DayIntakeEvidence(
                    loggedMealCount: day.nativeMeals,
                    hasReconstructedDietaryEnergy: !native && day.hasImport,
                    markedDidNotTrack: day.marked
                )
            )
        }
    }
}

/// One calendar day's running totals while reading meals.
private struct IntakeDayTally {
    var nativeKcal = 0.0
    var importedKcal = 0.0
    var nativeMeals = 0
    var hasImport = false
    var marked = false
}

/// Everything a live recomputation depends on. Two equal keys give equal
/// results, so a caller that keeps the last key recomputes only when one of
/// the spec §3 triggers has fired.
public struct EnergyRecomputeKey: Sendable, Hashable {
    /// Start of the day being computed ("today").
    public let day: Date
    /// Start of the first rendered day of the live series.
    public let historyFrom: Date
    /// Stored intake from `historyFrom` minus the window through today.
    public let intake: [DayIntake]
    public let weights: TrendSeries
    public let schedule: FormulaActivationSchedule
    public let rateGoal: RateGoal
}

/// Why a recomputation is due (spec §3 "Recompute": daily at first
/// foreground, and on any backfill edit, correction or α change; plus a
/// formula activation or a new rate goal, which change the live numbers).
public enum EnergyRecomputeReason: String, Sendable, Hashable, CaseIterable {
    /// Nothing has been computed yet.
    case firstRun
    /// The first computation of a new calendar day.
    case newDay
    /// Stored intake changed: a meal logged, edited or deleted, a backfill,
    /// an import, or a "didn't track" mark.
    case intakeChanged
    /// The weight series changed: a weigh-in or a correction.
    case weightChanged
    /// The trend smoothing α changed.
    case smoothingChanged
    /// The formula activation schedule changed.
    case formulaActivated
    case rateGoalChanged
    /// The caller asked for a different stretch of history.
    case historyRangeChanged

    /// The reasons to recompute when the inputs are now `current` and were
    /// `previous` at the last computation; empty means the last result still
    /// stands.
    public static func reasons(from previous: EnergyRecomputeKey?, to current: EnergyRecomputeKey) -> Set<Self> {
        guard let previous else { return [.firstRun] }
        var reasons: Set<Self> = []
        if previous.day != current.day { reasons.insert(.newDay) }
        if previous.historyFrom != current.historyFrom { reasons.insert(.historyRangeChanged) }
        if previous.intake != current.intake { reasons.insert(.intakeChanged) }
        if previous.weights.points != current.weights.points { reasons.insert(.weightChanged) }
        if previous.weights.smoothing != current.weights.smoothing { reasons.insert(.smoothingChanged) }
        if previous.schedule != current.schedule { reasons.insert(.formulaActivated) }
        if previous.rateGoal != current.rateGoal { reasons.insert(.rateGoalChanged) }
        return reasons
    }
}

/// One live recomputation: the series, today's state and the numbers the
/// target card shows. Derived, never stored.
public struct LiveEnergy: Sendable, Hashable {
    public let key: EnergyRecomputeKey
    /// The live series from `historyFrom` through today, each day under the
    /// version active on it (forward-only activation, spec §3).
    public let history: RenderedHistory
    /// Today's evaluation under today's active version.
    public let evaluation: ExpenditureEvaluation
    /// The calculated target from today's estimate. Nil while paused: a
    /// paused engine shows its last valid estimate, it does not manufacture
    /// a new target from it.
    public let calculatedTarget: CalculatedTarget?
    /// The quiet re-adoption suggestion against the stored open period.
    public let readoptionSuggestion: ReadoptionSuggestion?

    /// Today's rendered day (the last day of ``history``).
    public var today: RenderedHistoryDay? { history.days.last }
}

@MainActor
public enum EnergyBinding {
    /// The recompute key for `today`, reading intake from the store.
    public static func key(
        store: some MealStore,
        today: Date,
        historyFrom: Date,
        weights: TrendSeries,
        schedule: FormulaActivationSchedule,
        rateGoal: RateGoal,
        calendar: Calendar,
        markedDidNotTrack: Set<Date> = []
    ) throws -> EnergyRecomputeKey {
        let day = calendar.startOfDay(for: today)
        let from = calendar.startOfDay(for: historyFrom)
        let intakeStart = calendar.date(byAdding: .day, value: -ExpenditureFormulaV1.windowDays, to: from)
            .map { calendar.startOfDay(for: $0) } ?? from
        let intake = try store.dayIntakes(
            from: intakeStart, through: day, calendar: calendar, markedDidNotTrack: markedDidNotTrack
        )
        return EnergyRecomputeKey(
            day: day, historyFrom: from, intake: intake, weights: weights, schedule: schedule, rateGoal: rateGoal
        )
    }

    /// Recomputes the live series, today's calculated target and the
    /// re-adoption suggestion. Reads the store; writes nothing.
    public static func recompute(
        store: some MealStore & TargetStore,
        key: EnergyRecomputeKey,
        calendar: Calendar
    ) throws -> LiveEnergy {
        let history = EnergyHistory.live(
            schedule: key.schedule, from: key.historyFrom, through: key.day,
            intake: key.intake, weights: key.weights, calendar: calendar
        )
        let evaluation = key.schedule.formula(on: key.day, calendar: calendar).evaluate(
            on: key.day, intake: key.intake, weights: key.weights, calendar: calendar
        )
        let calculated = evaluation.estimate.flatMap { CalculatedTarget(estimate: $0, rateGoal: key.rateGoal) }
        let suggestion = try calculated.flatMap { try store.targetLedger().readoptionSuggestion(live: $0) }
        return LiveEnergy(
            key: key,
            history: history,
            evaluation: evaluation,
            calculatedTarget: calculated,
            readoptionSuggestion: suggestion
        )
    }

    /// ``key(store:today:historyFrom:weights:schedule:rateGoal:calendar:markedDidNotTrack:)``
    /// then ``recompute(store:key:calendar:)``.
    public static func recompute(
        store: some MealStore & TargetStore,
        today: Date,
        historyFrom: Date,
        weights: TrendSeries,
        schedule: FormulaActivationSchedule,
        rateGoal: RateGoal,
        calendar: Calendar,
        markedDidNotTrack: Set<Date> = []
    ) throws -> LiveEnergy {
        let key = try key(
            store: store, today: today, historyFrom: historyFrom, weights: weights,
            schedule: schedule, rateGoal: rateGoal, calendar: calendar, markedDidNotTrack: markedDidNotTrack
        )
        return try recompute(store: store, key: key, calendar: calendar)
    }
}
