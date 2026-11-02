// SPDX-License-Identifier: GPL-3.0-or-later
// Pause honesty independent of the rendered range (fl-m3-06): the live
// series carries the last valid estimate however late it starts (spec §3
// "Paused behavior", acceptance #3, and "Versioning").
//
// Fixture: TargetFixture (trend 80 − 0.0625·k kg on days −22...40, 2000 kcal
// on days 0...40) with days 20–27 marked "didn't track". Expected values were
// computed by hand and with a throwaway script outside the repo from the
// spec §3 formula text, not from this module's output:
// - day −22 and earlier: paused, no data (nothing inside the window)
// - days −21...13: paused, insufficient intake; nothing tracked yet
// - days 14...27: tracking (day 27's window 6–26 holds 14 complete days);
//   2481.25 kcal/day under v1, 2437.5 under v2
// - day 28 onward: 13 complete days in every window, paused for
//   insufficient intake; the displayed estimate stays day 27's
import Foundation
import Testing
@testable import FLEnergyCore

private typealias F = TargetFixture

private let v1Name = "FL-EB v1"
private let v2Name = "FL-EB v2 (synthetic)"

/// The fixture's intake with days 20–27 marked "didn't track".
private let pausedIntake: [DayIntake] = (0...40).map {
    DayIntake(
        day: F.noon($0),
        intakeKcal: 2_000,
        evidence: DayIntakeEvidence(loggedMealCount: 2, markedDidNotTrack: (20...27).contains($0))
    )
}

private func live(
    from first: Int,
    through last: Int,
    schedule: FormulaActivationSchedule = FormulaActivationSchedule(),
    intake: [DayIntake] = pausedIntake
) -> RenderedHistory {
    EnergyHistory.live(
        schedule: schedule, from: F.day(first), through: F.day(last),
        intake: intake, weights: F.weights, calendar: F.utc
    )
}

@Suite("Live series: pause honesty independent of the rendered range")
struct LiveSeedTests {
    @Test(
        "live(from: F) is the full-history live series with the days before F dropped",
        arguments: [-40, -30, -22, -21, -5, 0, 10, 13, 14, 20, 27, 28, 29, 31, 32]
    )
    func invariant(first: Int) throws {
        let schedule = try FormulaActivationSchedule().activating(F.v2, from: F.day(30), calendar: F.utc)
        // Day −40 is before every stored datum: the plain fold, nothing
        // dropped.
        let full = live(from: -40, through: 32, schedule: schedule)
        #expect(full.days.count == 73)
        #expect(full.days.first?.day == F.day(-40))

        let partial = live(from: first, through: 32, schedule: schedule)
        let expected = full.days.filter { $0.day >= F.day(first) }
        #expect(partial.label == .asRecorded)
        #expect(partial.days.count == 32 - first + 1)
        #expect(partial.days.first?.day == F.day(first))
        #expect(partial.days == expected)
        #expect(try F.bytes(partial.days) == F.bytes(expected))
    }

    @Test("the full series matches the hand-computed states and carried values")
    func fullSeriesSpotChecks() throws {
        let schedule = try FormulaActivationSchedule().activating(F.v2, from: F.day(30), calendar: F.utc)
        let full = live(from: -40, through: 32, schedule: schedule)
        func day(_ offset: Int) throws -> RenderedHistoryDay {
            try #require(full.days.first { $0.day == F.day(offset) })
        }
        #expect(try day(-22).state == .pausedNoData)
        #expect(try day(-21).state == .pausedInsufficientIntake)
        #expect(try day(13).state == .pausedInsufficientIntake)
        #expect(try day(13).displayedKcalPerDay == nil)
        #expect(try day(13).displayedFormulaName == nil)
        #expect(try day(14).state == .tracking)
        #expect(try day(14).displayedKcalPerDay == 2_481.25)
        #expect(try day(27).state == .tracking)
        #expect(try day(27).displayedAsOf == F.day(27))
        for offset in 28...32 {
            let rendered = try day(offset)
            #expect(rendered.state == .pausedInsufficientIntake)
            #expect(rendered.displayedKcalPerDay == 2_481.25)
            #expect(rendered.displayedAsOf == F.day(27))
            #expect(rendered.displayedFormulaName == v1Name)
        }
    }

    @Test("paused today rendered alone shows the last valid estimate and its as-of date, no new value")
    func pausedTodayAlone() throws {
        let today = live(from: 28, through: 28)
        #expect(today.days.count == 1)
        let day = try #require(today.days.first)
        #expect(day.day == F.day(28))
        #expect(day.state == .pausedInsufficientIntake)
        #expect(day.displayedKcalPerDay == 2_481.25)
        #expect(day.displayedAsOf == F.day(27))
        #expect(day.formulaName == v1Name)
        #expect(day.displayedFormulaName == v1Name)

        // Long after the last tracking day, still the same value and date.
        let later = try #require(live(from: 44, through: 44).days.first)
        #expect(later.state == .pausedInsufficientIntake)
        #expect(later.displayedKcalPerDay == 2_481.25)
        #expect(later.displayedAsOf == F.day(27))

        // No new estimate is emitted while paused: every paused day of a
        // longer rendering shows exactly day 27's value and date.
        let pausedStretch = live(from: 28, through: 44)
        #expect(pausedStretch.days.count == 17)
        #expect(pausedStretch.days.allSatisfy {
            $0.state == .pausedInsufficientIntake
                && $0.displayedKcalPerDay == 2_481.25
                && $0.displayedAsOf == F.day(27)
        })
    }

    @Test("a carried estimate keeps the earlier version's name and value, not today's version's")
    func carriedEstimateKeepsItsVersion() throws {
        // v2 activates on day 28, the first paused day: today is evaluated
        // under v2, but what it shows was made under v1 on day 27.
        let schedule = try FormulaActivationSchedule().activating(F.v2, from: F.day(28), calendar: F.utc)
        let today = try #require(live(from: 28, through: 28, schedule: schedule).days.first)
        #expect(today.formulaName == v2Name)
        #expect(today.state == .pausedInsufficientIntake)
        #expect(today.displayedKcalPerDay == 2_481.25) // v1's value, not v2's 2437.5
        #expect(today.displayedAsOf == F.day(27))
        #expect(today.displayedFormulaName == v1Name)

        // Control: without the pause, day 28 tracks under v2 itself.
        let tracking = try #require(live(from: 28, through: 28, schedule: schedule, intake: F.intake()).days.first)
        #expect(tracking.state == .tracking)
        #expect(tracking.formulaName == v2Name)
        #expect(tracking.displayedKcalPerDay == 2_437.5)
        #expect(tracking.displayedAsOf == F.day(28))
        #expect(tracking.displayedFormulaName == v2Name)
    }

    @Test("an estimate made under a version that is still active is carried with that version")
    func carriedUnderSameVersion() throws {
        // v2 active from day 25: days 25–27 track at 2437.5 under v2.
        let schedule = try FormulaActivationSchedule().activating(F.v2, from: F.day(25), calendar: F.utc)
        let today = try #require(live(from: 30, through: 30, schedule: schedule).days.first)
        #expect(today.formulaName == v2Name)
        #expect(today.displayedKcalPerDay == 2_437.5)
        #expect(today.displayedAsOf == F.day(27))
        #expect(today.displayedFormulaName == v2Name)
    }

    @Test("the seed is the earliest intake or weigh-in day; with neither, the series starts at the first day")
    func seedDay() {
        #expect(EnergyHistory.seedDay(intake: pausedIntake, weights: F.weights, calendar: F.utc) == F.day(-22))
        let laterWeights = TrendSeries(smoothing: .standard, points: Array(F.weights.points.dropFirst(30)))
        #expect(EnergyHistory.seedDay(intake: pausedIntake, weights: laterWeights, calendar: F.utc) == F.day(0))
        let none = TrendSeries(smoothing: .standard, points: [])
        #expect(EnergyHistory.seedDay(intake: [], weights: none, calendar: F.utc) == nil)

        // No data at all: the requested range, every day paused with no value.
        let empty = EnergyHistory.live(
            schedule: FormulaActivationSchedule(), from: F.day(3), through: F.day(5),
            intake: [], weights: none, calendar: F.utc
        )
        #expect(empty.days.map(\.day) == [F.day(3), F.day(4), F.day(5)])
        #expect(empty.days.allSatisfy { $0.state == .pausedNoData && $0.displayedKcalPerDay == nil })
    }

    @Test("period renderings and the re-run action keep folding from their own first day")
    func otherRenderingsKeepTheirBounds() throws {
        // The re-run from paused day 28 has nothing to carry: it is a
        // separate, labeled reconstruction of that range only.
        let rerun = EnergyHistory.rerun(
            with: .builtinV1, from: F.day(28), through: F.day(29),
            intake: pausedIntake, weights: F.weights, calendar: F.utc
        )
        #expect(rerun.label == .reconstructed)
        #expect(rerun.days.map(\.state) == [.pausedInsufficientIntake, .pausedInsufficientIntake])
        #expect(rerun.days.allSatisfy {
            $0.displayedKcalPerDay == nil && $0.displayedAsOf == nil && $0.displayedFormulaName == nil
        })

        // A period opened on day 28 renders its own days from its start.
        let estimate = try #require(EnergyFormulaVersion.builtinV1.evaluate(
            on: F.noon(27), intake: pausedIntake, weights: F.weights, calendar: F.utc
        ).estimate)
        let calculated = try #require(CalculatedTarget(estimate: estimate, rateGoal: F.rate(-0.5)))
        let ledger = try TargetLedger().adopting(
            TargetAdoption(calculated: calculated, macros: F.macros(), formula: .builtinV1),
            on: F.noon(28), calendar: F.utc, id: F.uuid(1)
        ).ledger
        let period = EnergyHistory.render(
            period: ledger.periods[0], through: F.day(29),
            intake: pausedIntake, weights: F.weights, calendar: F.utc
        )
        #expect(period.history.days.map(\.day) == [F.day(28), F.day(29)])
        #expect(period.history.days.allSatisfy { $0.displayedKcalPerDay == nil })
    }
}
