// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How a rendered history was produced (spec §3 "Versioning").
public enum HistoryLabel: String, Sendable, Hashable, Codable {
    /// Rendered with the formula version that applied at the time: a
    /// period's pinned version, or the version active on each day.
    case asRecorded
    /// The explicit "re-run history with vN" action: past days recomputed
    /// under a version that did not apply then. Always labeled, never
    /// silent.
    case reconstructed
}

/// One rendered day of expenditure history, plain values only so the
/// rendering can be compared byte for byte.
public struct RenderedHistoryDay: Sendable, Hashable, Codable {
    /// Start of the calendar day.
    public let day: Date
    /// Name of the formula version the day was evaluated with.
    public let formulaName: String
    public let state: RenderedState
    /// The estimate on screen that day: the new one while tracking, the last
    /// valid one while paused, nil if none exists yet.
    public let displayedKcalPerDay: Double?
    /// As-of date of ``displayedKcalPerDay``.
    public let displayedAsOf: Date?

    public enum RenderedState: String, Sendable, Hashable, Codable {
        case tracking
        case pausedInsufficientIntake
        case pausedInsufficientWeight
        case pausedNoData

        init(_ state: ExpenditureState) {
            switch state {
            case .tracking: self = .tracking
            case .paused(.insufficientIntake): self = .pausedInsufficientIntake
            case .paused(.insufficientWeight): self = .pausedInsufficientWeight
            case .paused(.noData): self = .pausedNoData
            }
        }
    }

    init(formulaName: String, snapshot: ExpenditureSnapshot) {
        day = snapshot.day
        self.formulaName = formulaName
        state = RenderedState(snapshot.state)
        displayedKcalPerDay = snapshot.displayed?.kcalPerDay
        displayedAsOf = snapshot.displayed?.asOf
    }
}

/// A rendered stretch of expenditure history with its label.
public struct RenderedHistory: Sendable, Hashable, Codable {
    public let label: HistoryLabel
    public let days: [RenderedHistoryDay]

    public var isReconstructed: Bool { label == .reconstructed }
}

/// A TargetPeriod rendered for history: its pinned values plus its days'
/// expenditure under its pinned formula version.
public struct RenderedTargetPeriod: Sendable, Hashable, Codable {
    public let period: AdoptedTargetPeriod
    public let history: RenderedHistory
}

/// Rendering of past and live expenditure under formula versions (spec §3
/// "Versioning"). Pure functions over plain values; results are derived and
/// recomputable, never canonical.
///
/// Each rendering folds snapshots from its first day, so the first day of a
/// rendering shows no carried-over estimate if it is paused.
public enum EnergyHistory {
    /// Renders `period` with the formula version it pinned, for every day
    /// from its start through its end, or through `lastDay` while it is open
    /// (and never past `lastDay`). Activating another version changes
    /// nothing here.
    public static func render(
        period: AdoptedTargetPeriod,
        through lastDay: Date,
        intake: [DayIntake],
        weights: TrendSeries,
        calendar: Calendar
    ) -> RenderedTargetPeriod {
        let limit = calendar.startOfDay(for: lastDay)
        let end = period.endDate.map { min($0, limit) } ?? limit
        let days = days(
            from: period.startDate, through: end, calendar: calendar,
            formula: { _ in period.formula }, intake: intake, weights: weights
        )
        return RenderedTargetPeriod(period: period, history: RenderedHistory(label: .asRecorded, days: days))
    }

    /// Renders every period of `ledger`, each with its pinned version.
    public static func render(
        ledger: TargetLedger,
        through lastDay: Date,
        intake: [DayIntake],
        weights: TrendSeries,
        calendar: Calendar
    ) -> [RenderedTargetPeriod] {
        ledger.periods.map {
            render(period: $0, through: lastDay, intake: intake, weights: weights, calendar: calendar)
        }
    }

    /// The live daily series: each day evaluated with the version active on
    /// it, so a new activation affects its day and later days only.
    public static func live(
        schedule: FormulaActivationSchedule,
        from first: Date,
        through last: Date,
        intake: [DayIntake],
        weights: TrendSeries,
        calendar: Calendar
    ) -> RenderedHistory {
        let days = days(
            from: first, through: last, calendar: calendar,
            formula: { schedule.formula(on: $0, calendar: calendar) },
            intake: intake, weights: weights
        )
        return RenderedHistory(label: .asRecorded, days: days)
    }

    /// The explicit "re-run history with vN" action: every day from `first`
    /// through `last` recomputed with `formula`, labeled reconstructed. It
    /// returns a separate rendering and changes no period or schedule.
    public static func rerun(
        with formula: EnergyFormulaVersion,
        from first: Date,
        through last: Date,
        intake: [DayIntake],
        weights: TrendSeries,
        calendar: Calendar
    ) -> RenderedHistory {
        let days = days(
            from: first, through: last, calendar: calendar,
            formula: { _ in formula }, intake: intake, weights: weights
        )
        return RenderedHistory(label: .reconstructed, days: days)
    }

    static func days(
        from first: Date,
        through last: Date,
        calendar: Calendar,
        formula: (Date) -> EnergyFormulaVersion,
        intake: [DayIntake],
        weights: TrendSeries
    ) -> [RenderedHistoryDay] {
        let records = ExpenditureEstimator.mergedDays(intake, calendar: calendar)
        let lastDay = calendar.startOfDay(for: last)
        var current = calendar.startOfDay(for: first)
        var previous: ExpenditureSnapshot?
        var rendered: [RenderedHistoryDay] = []
        while current <= lastDay {
            let version = formula(current)
            let evaluation = ExpenditureEstimator.evaluate(
                on: current, days: records, weights: weights, calendar: calendar,
                parameters: version.parameters
            )
            let snapshot = ExpenditureSnapshot.advance(from: previous, day: current, evaluation: evaluation)
            rendered.append(RenderedHistoryDay(formulaName: version.name, snapshot: snapshot))
            previous = snapshot
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = calendar.startOfDay(for: next)
        }
        return rendered
    }
}
