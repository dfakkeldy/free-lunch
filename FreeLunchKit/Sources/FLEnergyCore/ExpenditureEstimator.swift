// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The builtin expenditure formula, `FL-EB v1` (spec §3 "Expenditure
/// estimator").
///
/// Over the trailing window of ``windowDays`` calendar days ending yesterday:
///
/// ```
/// expenditure/day = Σ intake(complete days) / n_complete
///                 − (Δtrend over W) × ρ / W_days
/// ```
///
/// Every change to this math ships as a new formula version; nothing here is
/// edited in place once released.
public enum ExpenditureFormulaV1 {
    /// Stable identifier pinned by TargetPeriods (spec §3 "Versioning").
    public static let identifier = "FL-EB v1"
    /// Trailing window length W, in calendar days, ending yesterday.
    public static let windowDays = 21
    /// Validity gate: at least this many intake-complete days in the window.
    public static let minimumCompleteIntakeDays = 14
    /// Default energy density ρ of body-mass change, kcal per kg.
    public static let defaultEnergyDensityKcalPerKg: Double = 7_700
}

/// The tunable inputs of the formula. ρ is a named constant that the formula
/// workbench (spec §4) may override; W and the 14-day gate belong to the
/// formula version itself.
public struct ExpenditureParameters: Sendable, Hashable {
    /// Energy density ρ, kcal per kg of trend change.
    public let energyDensityKcalPerKg: Double

    /// The shipped `FL-EB v1` parameters (ρ = 7700 kcal/kg).
    public static let standard = ExpenditureParameters(
        validatedEnergyDensity: ExpenditureFormulaV1.defaultEnergyDensityKcalPerKg
    )

    /// Returns nil unless ρ is finite and positive.
    public init?(energyDensityKcalPerKg: Double) {
        guard energyDensityKcalPerKg.isFinite, energyDensityKcalPerKg > 0 else { return nil }
        self.energyDensityKcalPerKg = energyDensityKcalPerKg
    }

    private init(validatedEnergyDensity: Double) {
        energyDensityKcalPerKg = validatedEnergyDensity
    }
}

/// One calendar day's intake as the engine consumes it: the day's total
/// energy plus the evidence that decides whether the day counts (spec §3
/// "Day completeness"). Logged and reconstructed (imported) intake are
/// treated alike.
public struct DayIntake: Sendable, Hashable {
    /// Any instant on the calendar day; the estimator keys it by
    /// `calendar.startOfDay(for:)`.
    public let day: Date
    /// Total intake for the day, kcal.
    public let intakeKcal: Double
    public let evidence: DayIntakeEvidence

    public init(day: Date, intakeKcal: Double, evidence: DayIntakeEvidence) {
        self.day = day
        self.intakeKcal = intakeKcal
        self.evidence = evidence
    }
}

/// Why an estimate is paused (spec §3 validity gate).
public enum ExpenditurePauseReason: Sendable, Hashable {
    /// Fewer than 14 intake-complete days in the window.
    case insufficientIntake
    /// The window is not weight-complete, or the trend is not defined at
    /// both ends of the window.
    case insufficientWeight
    /// No intake-complete day and no weigh-in inside the window.
    case noData
}

/// The engine's state for one evaluation day.
public enum ExpenditureState: Sendable, Hashable {
    case tracking
    case paused(ExpenditurePauseReason)
}

/// A valid expenditure estimate with every term that produced it, so the
/// number can be shown with its working (transparent recalculation).
public struct ExpenditureEstimate: Sendable, Hashable {
    /// Estimated expenditure, kcal/day.
    public let kcalPerDay: Double
    /// The as-of date: start of the calendar day the estimate was computed
    /// for. Its window ends the day before.
    public let asOf: Date
    /// Start of the first calendar day in the window.
    public let windowFirstDay: Date
    /// Start of the last calendar day in the window (yesterday, relative to
    /// ``asOf``).
    public let windowLastDay: Date
    /// n_complete: intake-complete days that entered the mean.
    public let completeIntakeDays: Int
    /// Σ intake(complete days) / n_complete, kcal/day.
    public let meanIntakeKcal: Double
    /// Trend at the end of the window minus trend just before it, kg.
    public let trendDeltaKg: Double
    /// ρ used, kcal/kg.
    public let energyDensityKcalPerKg: Double
    /// The formula version that produced the value.
    public let formula: String

    public init(
        kcalPerDay: Double,
        asOf: Date,
        windowFirstDay: Date,
        windowLastDay: Date,
        completeIntakeDays: Int,
        meanIntakeKcal: Double,
        trendDeltaKg: Double,
        energyDensityKcalPerKg: Double,
        formula: String
    ) {
        self.kcalPerDay = kcalPerDay
        self.asOf = asOf
        self.windowFirstDay = windowFirstDay
        self.windowLastDay = windowLastDay
        self.completeIntakeDays = completeIntakeDays
        self.meanIntakeKcal = meanIntakeKcal
        self.trendDeltaKg = trendDeltaKg
        self.energyDensityKcalPerKg = energyDensityKcalPerKg
        self.formula = formula
    }
}

/// The outcome of evaluating one day. A paused evaluation structurally
/// carries no value: nothing is manufactured while the gate is closed.
public enum ExpenditureEvaluation: Sendable, Hashable {
    case tracking(ExpenditureEstimate)
    case paused(ExpenditurePauseReason)

    public var state: ExpenditureState {
        switch self {
        case .tracking: .tracking
        case let .paused(reason): .paused(reason)
        }
    }

    /// The newly emitted estimate, or nil while paused.
    public var estimate: ExpenditureEstimate? {
        if case let .tracking(estimate) = self { estimate } else { nil }
    }
}

/// What the app shows for one evaluation day.
///
/// While paused, the last valid estimate stays on screen with its own as-of
/// date and the reason: never extrapolated, never silently frozen.
public struct ExpenditureSnapshot: Sendable, Hashable {
    /// Start of the evaluation day.
    public let day: Date
    public let evaluation: ExpenditureEvaluation
    /// The most recent valid estimate on or before ``day``; equal to the new
    /// estimate when tracking, unchanged (old as-of date included) while
    /// paused, nil if no valid estimate has existed yet.
    public let displayed: ExpenditureEstimate?

    public init(day: Date, evaluation: ExpenditureEvaluation, displayed: ExpenditureEstimate?) {
        self.day = day
        self.evaluation = evaluation
        self.displayed = displayed
    }

    public var state: ExpenditureState { evaluation.state }

    /// Folds one day's evaluation onto the previous snapshot.
    public static func advance(
        from previous: ExpenditureSnapshot?,
        day: Date,
        evaluation: ExpenditureEvaluation
    ) -> ExpenditureSnapshot {
        ExpenditureSnapshot(
            day: day,
            evaluation: evaluation,
            displayed: evaluation.estimate ?? previous?.displayed
        )
    }
}

/// The `FL-EB v1` expenditure estimator. Pure functions over plain values;
/// the result is derived and recomputable, never canonical.
///
/// Decisions this implementation pins down:
/// - The window is the ``ExpenditureFormulaV1/windowDays`` calendar days
///   before `today` in the injected calendar. A weigh-in at exactly today's
///   midnight belongs to today and is outside the window.
/// - Δtrend = trend at the last instant of yesterday − trend at the last
///   instant before the window's first day (trend holds its last value
///   between weigh-ins). Both must be defined: the formula divides by
///   W_days = 21, so a slope over a shorter span would be manufactured. A
///   missing start trend pauses with ``ExpenditurePauseReason/insufficientWeight``.
///   This is in addition to ``DayCompleteness/weight(window:series:)``
///   (trend defined at the end and ≥2 weigh-ins inside).
/// - Reason precedence: ``ExpenditurePauseReason/noData`` (no complete intake
///   day and no weigh-in inside the window), then
///   ``ExpenditurePauseReason/insufficientIntake``, then
///   ``ExpenditurePauseReason/insufficientWeight``.
/// - Several records for one calendar day are merged: kcal and meal counts
///   are summed, the reconstructed and "didn't track" flags are OR'ed.
/// - A complete day whose merged intake is negative or not finite is not a
///   usable intake day: it is left out of both Σ and n_complete.
public enum ExpenditureEstimator {
    /// Evaluates the estimate for `today` (any instant on that calendar day).
    public static func evaluate(
        on today: Date,
        intake: [DayIntake],
        weights: TrendSeries,
        calendar: Calendar,
        parameters: ExpenditureParameters = .standard
    ) -> ExpenditureEvaluation {
        let days = mergedDays(intake, calendar: calendar)
        return evaluate(on: today, days: days, weights: weights, calendar: calendar, parameters: parameters)
    }

    /// Recomputes the snapshot sequence for every calendar day from `first`
    /// through `last` (inclusive). The fold starts empty at `first`, so a
    /// paused first day shows no estimate.
    public static func timeline(
        from first: Date,
        through last: Date,
        intake: [DayIntake],
        weights: TrendSeries,
        calendar: Calendar,
        parameters: ExpenditureParameters = .standard
    ) -> [ExpenditureSnapshot] {
        let days = mergedDays(intake, calendar: calendar)
        let lastDay = calendar.startOfDay(for: last)
        var current = calendar.startOfDay(for: first)
        var snapshots: [ExpenditureSnapshot] = []
        while current <= lastDay {
            let evaluation = evaluate(
                on: current, days: days, weights: weights, calendar: calendar, parameters: parameters
            )
            snapshots.append(.advance(from: snapshots.last, day: current, evaluation: evaluation))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = calendar.startOfDay(for: next)
        }
        return snapshots
    }

    // MARK: - Internals

    struct MergedDay {
        var intakeKcal: Double
        var loggedMealCount: Int
        var hasReconstructedDietaryEnergy: Bool
        var markedDidNotTrack: Bool

        var evidence: DayIntakeEvidence {
            DayIntakeEvidence(
                loggedMealCount: loggedMealCount,
                hasReconstructedDietaryEnergy: hasReconstructedDietaryEnergy,
                markedDidNotTrack: markedDidNotTrack
            )
        }
    }

    static func mergedDays(_ records: [DayIntake], calendar: Calendar) -> [Date: MergedDay] {
        var days: [Date: MergedDay] = [:]
        for record in records {
            let key = calendar.startOfDay(for: record.day)
            var merged = days[key] ?? MergedDay(
                intakeKcal: 0,
                loggedMealCount: 0,
                hasReconstructedDietaryEnergy: false,
                markedDidNotTrack: false
            )
            merged.intakeKcal += record.intakeKcal
            merged.loggedMealCount += record.evidence.loggedMealCount
            merged.hasReconstructedDietaryEnergy = merged.hasReconstructedDietaryEnergy
                || record.evidence.hasReconstructedDietaryEnergy
            merged.markedDidNotTrack = merged.markedDidNotTrack || record.evidence.markedDidNotTrack
            days[key] = merged
        }
        return days
    }

    /// The instant just before `date`: the last moment of the previous day
    /// when `date` is a midnight.
    static func instantBefore(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextDown)
    }

    static func evaluate(
        on today: Date,
        days: [Date: MergedDay],
        weights: TrendSeries,
        calendar: Calendar,
        parameters: ExpenditureParameters
    ) -> ExpenditureEvaluation {
        let todayStart = calendar.startOfDay(for: today)
        let windowDays = ExpenditureFormulaV1.windowDays
        guard
            let firstDayRaw = calendar.date(byAdding: .day, value: -windowDays, to: todayStart),
            let lastDayRaw = calendar.date(byAdding: .day, value: -1, to: todayStart)
        else {
            return .paused(.noData)
        }
        let firstDay = calendar.startOfDay(for: firstDayRaw)
        let lastDay = calendar.startOfDay(for: lastDayRaw)

        // Intake over the window's calendar days.
        var intakeSum = 0.0
        var completeDays = 0
        var dayStart = firstDay
        while dayStart < todayStart {
            if let day = days[dayStart],
               DayCompleteness.intake(day.evidence).isComplete,
               day.intakeKcal.isFinite, day.intakeKcal >= 0 {
                intakeSum += day.intakeKcal
                completeDays += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            dayStart = calendar.startOfDay(for: next)
        }

        // Weight over the same span of instants.
        let windowEnd = instantBefore(todayStart)
        let window = firstDay...windowEnd
        let weighInsInside = weights.points.lazy.filter { window.contains($0.measuredAt) }.count

        if completeDays == 0 && weighInsInside == 0 {
            return .paused(.noData)
        }
        if completeDays < ExpenditureFormulaV1.minimumCompleteIntakeDays {
            return .paused(.insufficientIntake)
        }
        // The weight gate reads "trend defined" at both ends of the window
        // (settled 2026-11-03): the trend must exist just before the window's
        // first day and at the end of yesterday. Δtrend needs both ends, and
        // dividing a shorter span by 21 would manufacture a slope. A fresh
        // user with daily weigh-ins therefore waits until about day 27.
        guard
            DayCompleteness.weight(window: window, series: weights).isComplete,
            let trendEnd = weights.trend(asOf: windowEnd),
            let trendStart = weights.trend(asOf: instantBefore(firstDay))
        else {
            return .paused(.insufficientWeight)
        }

        let rho = parameters.energyDensityKcalPerKg
        let meanIntake = intakeSum / Double(completeDays)
        let trendDelta = trendEnd - trendStart
        let expenditure = meanIntake - trendDelta * rho / Double(windowDays)

        return .tracking(ExpenditureEstimate(
            kcalPerDay: expenditure,
            asOf: todayStart,
            windowFirstDay: firstDay,
            windowLastDay: lastDay,
            completeIntakeDays: completeDays,
            meanIntakeKcal: meanIntake,
            trendDeltaKg: trendDelta,
            energyDensityKcalPerKg: rho,
            formula: ExpenditureFormulaV1.identifier
        ))
    }
}
