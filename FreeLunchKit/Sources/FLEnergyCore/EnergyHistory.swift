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
    /// Name of the formula version that produced ``displayedKcalPerDay``, as
    /// recorded on its as-of day: equal to ``formulaName`` while tracking,
    /// the earlier day's version while paused (spec §3 "Versioning": a
    /// carried estimate is never recomputed under a later version). Nil
    /// when no estimate is displayed.
    public let displayedFormulaName: String?

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

    init(formulaName: String, snapshot: ExpenditureSnapshot, displayedFormulaName: String?) {
        day = snapshot.day
        self.formulaName = formulaName
        state = RenderedState(snapshot.state)
        displayedKcalPerDay = snapshot.displayed?.kcalPerDay
        displayedAsOf = snapshot.displayed?.asOf
        self.displayedFormulaName = snapshot.displayed == nil ? nil : displayedFormulaName
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
/// The live series does not depend on the range asked for: it is folded
/// from the earliest stored data, so a paused first day still shows the last
/// valid estimate (spec §3 "Paused behavior"). Period renderings and the
/// re-run action fold from their own first day instead.
public enum EnergyHistory {
    /// Renders `period` with the formula version it pinned, for every day
    /// from its start through its end, or through `lastDay` while it is open
    /// (and never past `lastDay`). Activating another version changes
    /// nothing here.
    ///
    /// The fold starts at the period's first day, so that day shows no
    /// carried-over estimate if it is paused.
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

    /// The live daily series from `first` through `last`: each day evaluated
    /// with the version active on it, so a new activation affects its day
    /// and later days only.
    ///
    /// The result does not depend on `first` beyond where it starts: the
    /// series is folded from the earliest day with any intake or weight data
    /// (or from `first`, if that is earlier), each day under its scheduled
    /// version, and the days before `first` are then dropped. A paused
    /// `first` day therefore shows the last valid estimate, its as-of date
    /// and the version that produced it (spec §3 "Paused behavior"). No day
    /// on or before the earliest data can track (its window holds no data),
    /// so starting there loses nothing.
    ///
    /// `intake` must hold every stored intake day through `last`, not only
    /// those in the requested range; a carried estimate can be older than
    /// any window inside it.
    public static func live(
        schedule: FormulaActivationSchedule,
        from first: Date,
        through last: Date,
        intake: [DayIntake],
        weights: TrendSeries,
        calendar: Calendar
    ) -> RenderedHistory {
        let firstDay = calendar.startOfDay(for: first)
        let start = seedDay(intake: intake, weights: weights, calendar: calendar).map { min($0, firstDay) } ?? firstDay
        let days = days(
            from: start, through: last, calendar: calendar,
            formula: { schedule.formula(on: $0, calendar: calendar) },
            intake: intake, weights: weights
        )
        return RenderedHistory(label: .asRecorded, days: days.filter { $0.day >= firstDay })
    }

    /// Start of the earliest calendar day with any intake record or weigh-in,
    /// or nil when there is neither.
    static func seedDay(intake: [DayIntake], weights: TrendSeries, calendar: Calendar) -> Date? {
        let earliestIntake = intake.lazy.map(\.day).min()
        // Points are kept in time order.
        let earliestWeight = weights.points.first?.measuredAt
        return [earliestIntake, earliestWeight].compactMap { $0 }.min().map { calendar.startOfDay(for: $0) }
    }

    /// The explicit "re-run history with vN" action: every day from `first`
    /// through `last` recomputed with `formula`, labeled reconstructed. It
    /// returns a separate rendering and changes no period or schedule.
    ///
    /// The fold starts at `first`, so that day shows no carried-over
    /// estimate if it is paused.
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
        // The version that produced `previous?.displayed`, as recorded.
        var displayedName: String?
        var rendered: [RenderedHistoryDay] = []
        while current <= lastDay {
            let version = formula(current)
            let evaluation = ExpenditureEstimator.evaluate(
                on: current, days: records, weights: weights, calendar: calendar,
                parameters: version.parameters
            )
            let snapshot = ExpenditureSnapshot.advance(from: previous, day: current, evaluation: evaluation)
            if evaluation.estimate != nil { displayedName = version.name }
            rendered.append(RenderedHistoryDay(
                formulaName: version.name, snapshot: snapshot, displayedFormulaName: displayedName
            ))
            previous = snapshot
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = calendar.startOfDay(for: next)
        }
        return rendered
    }
}
