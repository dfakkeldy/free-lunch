// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One adopted target (spec §1 TargetPeriod, semantics spec §3 "Adopted
/// target"). Every field is a `let`: recalculation has no way to change a
/// period. The only change a period ever sees is being closed by the next
/// explicit adoption, which sets ``endDate`` and nothing else.
public struct AdoptedTargetPeriod: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// Start of the first calendar day the period governs.
    public let startDate: Date
    /// Start of the last calendar day the period governs; nil while open.
    public let endDate: Date?
    /// The three separate values, locked apart (spec §1), kcal/day.
    public let expenditureAtAdoptionKcal: Double
    public let calculatedTargetKcal: Double
    public let adoptedTargetKcal: Double
    public let proteinTargetG: Double
    public let fatFloorPct: Double
    /// The formula version pinned at adoption, forever.
    public let formula: EnergyFormulaVersion

    public init(
        id: UUID,
        startDate: Date,
        endDate: Date?,
        expenditureAtAdoptionKcal: Double,
        calculatedTargetKcal: Double,
        adoptedTargetKcal: Double,
        proteinTargetG: Double,
        fatFloorPct: Double,
        formula: EnergyFormulaVersion
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.expenditureAtAdoptionKcal = expenditureAtAdoptionKcal
        self.calculatedTargetKcal = calculatedTargetKcal
        self.adoptedTargetKcal = adoptedTargetKcal
        self.proteinTargetG = proteinTargetG
        self.fatFloorPct = fatFloorPct
        self.formula = formula
    }

    public var isOpen: Bool { endDate == nil }

    /// The pinned macro targets.
    public var macros: MacroTargets? {
        MacroTargets(proteinTargetG: proteinTargetG, fatFloorPct: fatFloorPct)
    }

    /// Whether the period governs the calendar day starting at `dayStart`.
    /// A period closed on the day it opened (same-day re-adoption) governs
    /// no day.
    func governs(dayStart: Date) -> Bool {
        guard startDate <= dayStart else { return false }
        guard let endDate else { return true }
        return dayStart <= endDate
    }

    func closed(endDate: Date) -> AdoptedTargetPeriod {
        AdoptedTargetPeriod(
            id: id,
            startDate: startDate,
            endDate: endDate,
            expenditureAtAdoptionKcal: expenditureAtAdoptionKcal,
            calculatedTargetKcal: calculatedTargetKcal,
            adoptedTargetKcal: adoptedTargetKcal,
            proteinTargetG: proteinTargetG,
            fatFloorPct: fatFloorPct,
            formula: formula
        )
    }
}

/// How adoption happens. Suggest-only is the default (decision 2026-08-01);
/// weekly auto-adopt is an opt-in setting, and each automatic adoption is
/// still recorded as its own period through the same
/// ``TargetLedger/adopting(_:on:calendar:id:)`` path. Scheduling the weekly
/// run belongs to the persistence binding.
public enum AdoptionMode: String, Sendable, Hashable, Codable, CaseIterable {
    case suggestOnly
    case weeklyAutoAdopt

    public static let `default`: AdoptionMode = .suggestOnly
}

/// What the user adopts: the live calculated target, the number they chose
/// (equal to it unless they adjusted it before adopting), the macro targets
/// and the formula version the calculation ran under.
public struct TargetAdoption: Sendable, Hashable {
    public let calculated: CalculatedTarget
    public let adoptedTargetKcal: Double
    public let macros: MacroTargets
    public let formula: EnergyFormulaVersion

    /// `adoptedTargetKcal` defaults to the calculated target.
    public init(
        calculated: CalculatedTarget,
        adoptedTargetKcal: Double? = nil,
        macros: MacroTargets,
        formula: EnergyFormulaVersion
    ) {
        self.calculated = calculated
        self.adoptedTargetKcal = adoptedTargetKcal ?? calculated.kcalPerDay
        self.macros = macros
        self.formula = formula
    }
}

/// The result of an adoption: the new ledger, the period it opened and the
/// rail warnings to show. Warnings never stop the adoption.
public struct AdoptionOutcome: Sendable, Hashable {
    public let ledger: TargetLedger
    public let period: AdoptedTargetPeriod
    public let warnings: Set<TargetWarning>
}

/// A quiet re-adoption suggestion (spec §3): the live calculated target has
/// drifted from the adopted one by at least 5% of the adopted target or at
/// least 100 kcal. One tap re-adopts; ignoring it changes nothing.
public struct ReadoptionSuggestion: Sendable, Hashable {
    /// Drift that triggers a suggestion, percent of the adopted target.
    public static let minimumDriftPercent: Double = 5
    /// Drift that triggers a suggestion, kcal/day.
    public static let minimumDriftKcal: Double = 100

    public let adoptedTargetKcal: Double
    public let calculatedTargetKcal: Double
    /// calculated − adopted, kcal/day.
    public let driftKcal: Double

    /// A suggestion when |calculated − adopted| ≥ 100 kcal or ≥ 5% of the
    /// adopted target (both inclusive); nil otherwise.
    public static func evaluate(adoptedTargetKcal: Double, calculatedTargetKcal: Double) -> ReadoptionSuggestion? {
        let drift = calculatedTargetKcal - adoptedTargetKcal
        guard drift.isFinite else { return nil }
        let magnitude = abs(drift)
        // Compare as |drift| × 100 ≥ 5 × adopted so a drift of exactly 5%
        // is not lost to rounding in a division.
        let byKcal = magnitude >= minimumDriftKcal
        let byPercent = magnitude * 100 >= minimumDriftPercent * abs(adoptedTargetKcal)
        guard byKcal || byPercent else { return nil }
        return ReadoptionSuggestion(
            adoptedTargetKcal: adoptedTargetKcal,
            calculatedTargetKcal: calculatedTargetKcal,
            driftKcal: drift
        )
    }
}

/// The history of adopted targets, oldest first. A value type: adoption
/// returns a new ledger, and nothing that recalculates expenditure or the
/// calculated target takes or returns one, so a recalculation cannot alter
/// an adopted target (spec §3 acceptance #4).
public struct TargetLedger: Sendable, Hashable, Codable {
    public private(set) var periods: [AdoptedTargetPeriod]

    public init() {
        periods = []
    }

    /// Rebuilds a ledger from stored periods, oldest first.
    public init(periods: [AdoptedTargetPeriod]) {
        self.periods = periods
    }

    public enum AdoptionError: Error, Sendable, Hashable {
        /// The adopted number is not a finite, positive kcal value.
        case invalidAdoptedTarget
        /// The adoption day is before the open period's first day.
        case precedesOpenPeriod(openPeriodStart: Date)
    }

    /// The open period, if any (the last period, when it has no end date).
    public var openPeriod: AdoptedTargetPeriod? {
        guard let last = periods.last, last.isOpen else { return nil }
        return last
    }

    /// The period that governs `day`'s calendar day, if any.
    public func period(governing day: Date, calendar: Calendar) -> AdoptedTargetPeriod? {
        let dayStart = calendar.startOfDay(for: day)
        return periods.last { $0.governs(dayStart: dayStart) }
    }

    /// Explicit adoption on `day` (spec §3): closes the open period with
    /// endDate = yesterday and opens a new one from today pinning
    /// expenditure, calculated target, adopted target, macros and formula
    /// version.
    ///
    /// Re-adopting on the day the open period started closes that period
    /// with an end date before its start: it is kept as a record of the
    /// adoption but governs no day, and the new period takes over today.
    ///
    /// Rail warnings are checked against the adopted number and the rate
    /// goal; they are returned, never thrown.
    public func adopting(
        _ adoption: TargetAdoption,
        on day: Date,
        calendar: Calendar,
        id: UUID = UUID()
    ) throws(AdoptionError) -> AdoptionOutcome {
        let adopted = adoption.adoptedTargetKcal
        guard adopted.isFinite, adopted > 0 else { throw .invalidAdoptedTarget }

        let today = calendar.startOfDay(for: day)
        var next = periods
        if let open = openPeriod {
            guard today >= open.startDate else {
                throw .precedesOpenPeriod(openPeriodStart: open.startDate)
            }
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
                .map { calendar.startOfDay(for: $0) } ?? today
            next[next.count - 1] = open.closed(endDate: yesterday)
        }

        let period = AdoptedTargetPeriod(
            id: id,
            startDate: today,
            endDate: nil,
            expenditureAtAdoptionKcal: adoption.calculated.expenditureKcal,
            calculatedTargetKcal: adoption.calculated.kcalPerDay,
            adoptedTargetKcal: adopted,
            proteinTargetG: adoption.macros.proteinTargetG,
            fatFloorPct: adoption.macros.fatFloorPct,
            formula: adoption.formula
        )
        next.append(period)
        return AdoptionOutcome(
            ledger: TargetLedger(periods: next),
            period: period,
            warnings: TargetRails.warnings(targetKcal: adopted, rateGoal: adoption.calculated.rateGoal)
        )
    }

    /// The re-adoption suggestion for the open period against the live
    /// calculated target, or nil when there is no open period or the drift
    /// is under both thresholds. Reading this never changes the ledger.
    public func readoptionSuggestion(live: CalculatedTarget) -> ReadoptionSuggestion? {
        guard let open = openPeriod else { return nil }
        return ReadoptionSuggestion.evaluate(
            adoptedTargetKcal: open.adoptedTargetKcal,
            calculatedTargetKcal: live.kcalPerDay
        )
    }
}
