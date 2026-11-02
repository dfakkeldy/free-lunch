// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLEnergyCore

// Expected values were computed by hand and with a throwaway script outside
// the repo from the spec §3 formula text, not from this module's output:
// with the shared fixture, FL-EB v1 (ρ 7700) gives 2481.25 kcal/day and the
// synthetic v2 (ρ 7000) gives 2437.5 kcal/day on every tracking day.

private typealias F = TargetFixture

private let v1Name = "FL-EB v1"
private let v2Name = "FL-EB v2 (synthetic)"

private func adopt(
    _ ledger: TargetLedger,
    on offset: Int,
    formula: EnergyFormulaVersion,
    id: Int
) throws -> TargetLedger {
    let estimate = try #require(formula.evaluate(
        on: F.noon(offset), intake: F.intake(), weights: F.weights, calendar: F.utc
    ).estimate)
    let calculated = CalculatedTarget(estimate: estimate, rateGoal: F.rate(-0.5))
    return try ledger.adopting(
        TargetAdoption(calculated: calculated, macros: F.macros(), formula: formula),
        on: F.noon(offset), calendar: F.utc, id: F.uuid(id)
    ).ledger
}

@Suite("Formula versions (spec §3 \"Versioning\")")
struct FormulaVersionTests {
    @Test("the builtin is FL-EB v1 at ρ = 7700, with its expression text")
    func builtin() {
        let v1 = EnergyFormulaVersion.builtinV1
        #expect(v1.name == "FL-EB v1")
        #expect(v1.origin == .builtin("FL-EB v1"))
        #expect(v1.parameters.energyDensityKcalPerKg == 7_700)
        #expect(EnergyFormulaVersion.builtinV1Definition == "intake_mean - (trend_delta * rho / window_days)")
    }

    @Test("a version round-trips through Codable; a bad ρ does not decode")
    func codable() throws {
        let decoded = try JSONDecoder().decode(EnergyFormulaVersion.self, from: F.bytes(F.v2))
        #expect(decoded == F.v2)
        let bad = Data(#"{"name":"x","origin":{"userEdited":{}},"parameters":{"energyDensityKcalPerKg":0}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnergyFormulaVersion.self, from: bad)
        }
    }

    @Test("activation is forward-only")
    func forwardOnlyActivation() throws {
        let schedule = try FormulaActivationSchedule().activating(F.v2, from: F.noon(28), calendar: F.utc)
        #expect(schedule.formula(on: F.noon(27), calendar: F.utc) == .builtinV1)
        #expect(schedule.formula(on: F.day(28), calendar: F.utc) == F.v2)
        #expect(schedule.formula(on: F.noon(40), calendar: F.utc) == F.v2)
        #expect(schedule.latest == F.v2)

        #expect(throws: FormulaActivationSchedule.ActivationError.retroactive(latestEffectiveFrom: F.day(28))) {
            try schedule.activating(.builtinV1, from: F.noon(27), calendar: F.utc)
        }
        // Same day is allowed; the later activation wins that day.
        let back = try schedule.activating(.builtinV1, from: F.morning(28), calendar: F.utc)
        #expect(back.formula(on: F.noon(28), calendar: F.utc) == .builtinV1)
    }
}

@Suite("Version pinning (spec §3 acceptance #5)")
struct VersionPinningTests {
    @Test("activating a new version leaves prior periods and their rendered history byte-identical")
    func priorPeriodsByteIdentical() throws {
        var schedule = FormulaActivationSchedule()
        var ledger = try adopt(TargetLedger(), on: 21, formula: schedule.formula(on: F.day(21), calendar: F.utc), id: 1)
        ledger = try adopt(ledger, on: 25, formula: schedule.formula(on: F.day(25), calendar: F.utc), id: 2)

        let periodsBefore = ledger.periods
        let renderedBefore = EnergyHistory.render(
            ledger: ledger, through: F.day(27), intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        let bytesBefore = try F.bytes(renderedBefore)

        schedule = try schedule.activating(F.v2, from: F.day(28), calendar: F.utc)

        let renderedAfter = EnergyHistory.render(
            ledger: ledger, through: F.day(27), intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        #expect(ledger.periods == periodsBefore)
        #expect(try F.bytes(renderedAfter) == bytesBefore)

        // Spot-check the rendering itself: period 1 covers days 21–24 and
        // period 2 days 25–27, every day v1 at 2481.25.
        #expect(renderedAfter.map { $0.history.days.count } == [4, 3])
        #expect(renderedAfter[0].history.days.first?.day == F.day(21))
        #expect(renderedAfter[0].history.days.last?.day == F.day(24))
        for day in renderedAfter.flatMap(\.history.days) {
            #expect(day.formulaName == v1Name)
            #expect(day.state == .tracking)
            #expect(day.displayedKcalPerDay == 2_481.25)
            #expect(day.displayedAsOf == day.day)
        }
        #expect(renderedAfter.allSatisfy { $0.history.label == .asRecorded })
    }

    @Test("an open period keeps rendering with the version it pinned after a new activation")
    func openPeriodKeepsPinnedVersion() throws {
        let ledger = try adopt(TargetLedger(), on: 25, formula: .builtinV1, id: 1)
        _ = try FormulaActivationSchedule().activating(F.v2, from: F.day(28), calendar: F.utc)
        let rendered = EnergyHistory.render(
            period: ledger.periods[0], through: F.day(32),
            intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        #expect(rendered.history.days.count == 8) // days 25–32
        #expect(rendered.history.days.allSatisfy { $0.formulaName == v1Name && $0.displayedKcalPerDay == 2_481.25 })
    }

    @Test("forward days use the new math; past days of the live series are unchanged")
    func forwardDaysUseNewMath() throws {
        let v1Only = FormulaActivationSchedule()
        let withV2 = try v1Only.activating(F.v2, from: F.day(28), calendar: F.utc)

        let before = EnergyHistory.live(
            schedule: v1Only, from: F.day(21), through: F.day(32),
            intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        let after = EnergyHistory.live(
            schedule: withV2, from: F.day(21), through: F.day(32),
            intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        #expect(after.label == .asRecorded)
        #expect(after.days.count == 12)

        // Days 21–27: byte-identical to the series before the activation.
        let pastBefore = Array(before.days.prefix(7))
        let pastAfter = Array(after.days.prefix(7))
        #expect(try F.bytes(pastAfter) == F.bytes(pastBefore))
        #expect(pastAfter.allSatisfy { $0.formulaName == v1Name && $0.displayedKcalPerDay == 2_481.25 })

        // Days 28–32: the new version's math.
        let forward = after.days.dropFirst(7)
        #expect(forward.first?.day == F.day(28))
        #expect(forward.allSatisfy { $0.formulaName == v2Name && $0.displayedKcalPerDay == 2_437.5 })

        // A period adopted after the activation pins v2; earlier ones keep v1.
        var ledger = try adopt(TargetLedger(), on: 25, formula: withV2.formula(on: F.day(25), calendar: F.utc), id: 1)
        let firstPeriodBytes = try F.bytes(ledger.periods[0].formula)
        ledger = try adopt(ledger, on: 30, formula: withV2.formula(on: F.day(30), calendar: F.utc), id: 2)
        #expect(try F.bytes(ledger.periods[0].formula) == firstPeriodBytes)
        #expect(ledger.periods[0].formula == .builtinV1)
        #expect(ledger.periods[1].formula == F.v2)
        #expect(ledger.periods[1].expenditureAtAdoptionKcal == 2_437.5)
        #expect(ledger.periods[1].calculatedTargetKcal == 1_937.5) // 2437.5 − 0.5 × 7000 / 7
    }

    @Test("\"re-run history with vN\" output carries the reconstructed label")
    func rerunIsLabeledReconstructed() throws {
        let ledger = try adopt(TargetLedger(), on: 21, formula: .builtinV1, id: 1)
        let periodsBefore = try F.bytes(ledger)

        let rerun = EnergyHistory.rerun(
            with: F.v2, from: F.day(21), through: F.day(32),
            intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        #expect(rerun.label == .reconstructed)
        #expect(rerun.isReconstructed)
        #expect(rerun.days.count == 12)
        #expect(rerun.days.allSatisfy { $0.formulaName == v2Name && $0.displayedKcalPerDay == 2_437.5 })

        // The live rendering is not reconstructed, and the re-run touched no period.
        let live = EnergyHistory.live(
            schedule: FormulaActivationSchedule(), from: F.day(21), through: F.day(32),
            intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        #expect(!live.isReconstructed)
        #expect(try F.bytes(ledger) == periodsBefore)
    }

    @Test("rendered history keeps pause honesty: paused days show the state and no new value")
    func renderedPauses() throws {
        // Days 10–13 have fewer than 14 complete intake days; 14 tracks.
        let rendered = EnergyHistory.rerun(
            with: .builtinV1, from: F.day(10), through: F.day(15),
            intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        #expect(rendered.days.map(\.state) == [
            .pausedInsufficientIntake, .pausedInsufficientIntake, .pausedInsufficientIntake,
            .pausedInsufficientIntake, .tracking, .tracking
        ])
        #expect(rendered.days.prefix(4).allSatisfy { $0.displayedKcalPerDay == nil && $0.displayedAsOf == nil })
        #expect(rendered.days[4].displayedKcalPerDay == 2_481.25)
        #expect(rendered.days[4].displayedAsOf == F.day(14))
    }
}
