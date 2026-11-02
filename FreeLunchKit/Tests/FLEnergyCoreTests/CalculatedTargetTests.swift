// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLEnergyCore

// Expected values were computed by hand and with a throwaway script outside
// the repo from the spec §3 formula text, not from this module's output.

private typealias F = TargetFixture

@Suite("Calculated target: rate math (spec §3 acceptance #6)")
struct CalculatedTargetRateTests {
    @Test("rateGoal −0.5 kg/wk lowers the target by exactly 550 kcal/day at ρ = 7700")
    func halfKiloPerWeek() {
        let maintenance = CalculatedTarget(expenditureKcal: 2_481.25, rateGoal: .maintenance)
        let loss = CalculatedTarget(expenditureKcal: 2_481.25, rateGoal: F.rate(-0.5))
        #expect(maintenance.kcalPerDay == 2_481.25)
        #expect(loss.kcalPerDay == 1_931.25)
        #expect(loss.kcalPerDay - maintenance.kcalPerDay == -550)
        #expect(loss.rateAdjustmentKcal == -550)
        #expect(loss.energyDensityKcalPerKg == 7_700)
        #expect(loss.expenditureKcal == 2_481.25)
    }

    @Test("gain is positive: +0.25 kg/wk adds exactly 275 kcal/day")
    func gain() {
        let gain = CalculatedTarget(expenditureKcal: 2_000, rateGoal: F.rate(0.25))
        #expect(gain.kcalPerDay == 2_275)
    }

    @Test("ρ is honored: −0.5 kg/wk at ρ = 7000 is exactly −500 kcal/day")
    func overriddenDensity() throws {
        let rho = try #require(ExpenditureParameters(energyDensityKcalPerKg: 7_000))
        let target = CalculatedTarget(expenditureKcal: 2_437.5, rateGoal: F.rate(-0.5), parameters: rho)
        #expect(target.rateAdjustmentKcal == -500)
        #expect(target.kcalPerDay == 1_937.5)
    }

    @Test("from an estimate: uses its value and its ρ")
    func fromEstimate() throws {
        let evaluation = EnergyFormulaVersion.builtinV1.evaluate(
            on: F.noon(30), intake: F.intake(), weights: F.weights, calendar: F.utc
        )
        let estimate = try #require(evaluation.estimate)
        #expect(estimate.kcalPerDay == 2_481.25)
        let target = try #require(CalculatedTarget(estimate: estimate, rateGoal: F.rate(-0.5)))
        #expect(target.kcalPerDay == 1_931.25)

        let v2Estimate = try #require(F.v2.evaluate(
            on: F.noon(30), intake: F.intake(), weights: F.weights, calendar: F.utc
        ).estimate)
        #expect(v2Estimate.kcalPerDay == 2_437.5)
        let v2Target = try #require(CalculatedTarget(estimate: v2Estimate, rateGoal: F.rate(-0.5)))
        #expect(v2Target.kcalPerDay == 1_937.5)
    }

    @Test("an estimate with an invalid ρ yields no target instead of a default ρ", arguments: [0, -7_700, Double.nan])
    func invalidEstimateDensity(rho: Double) {
        let estimate = ExpenditureEstimate(
            kcalPerDay: 2_481.25, asOf: F.day(30), windowFirstDay: F.day(9), windowLastDay: F.day(29),
            completeIntakeDays: 21, meanIntakeKcal: 2_000, trendDeltaKg: -1.3125,
            energyDensityKcalPerKg: rho, formula: "FL-EB v1"
        )
        #expect(CalculatedTarget(estimate: estimate, rateGoal: F.rate(-0.5)) == nil)
    }

    @Test("a non-finite rate goal is rejected", arguments: [Double.nan, .infinity, -.infinity])
    func rejectsNonFiniteRate(rate: Double) {
        #expect(RateGoal(kgPerWeek: rate) == nil)
    }
}

@Suite("Calculated target: warn-only safety rails (spec §3 acceptance #7)")
struct SafetyRailTests {
    @Test("a target under 1200 kcal warns; exactly 1200 does not")
    func floor() {
        let below = CalculatedTarget(expenditureKcal: 1_749, rateGoal: F.rate(-0.5))
        #expect(below.kcalPerDay == 1_199)
        #expect(below.warnings == [.targetBelowFloor])

        let atFloor = CalculatedTarget(expenditureKcal: 1_750, rateGoal: F.rate(-0.5))
        #expect(atFloor.kcalPerDay == 1_200)
        #expect(atFloor.warnings.isEmpty)
    }

    @Test(
        "|rate| above 1.0 kg/wk warns; exactly 1.0 does not",
        arguments: [(-1.1, true), (1.01, true), (-1.0, false), (1.0, false), (0.0, false)]
    )
    func rate(kgPerWeek: Double, warns: Bool) {
        let target = CalculatedTarget(expenditureKcal: 4_000, rateGoal: F.rate(kgPerWeek))
        #expect(target.warnings.contains(.rateAboveLimit) == warns)
        #expect(!target.warnings.contains(.targetBelowFloor))
    }

    @Test("both rails at once: −1.5 kg/wk from 2500 kcal → 850 kcal, two warnings")
    func both() {
        let target = CalculatedTarget(expenditureKcal: 2_500, rateGoal: F.rate(-1.5))
        #expect(target.kcalPerDay == 850)
        #expect(target.warnings == [.targetBelowFloor, .rateAboveLimit])
    }

    @Test("a warned target still adopts and saves with its values")
    func warnedTargetStillSaves() throws {
        let calculated = CalculatedTarget(expenditureKcal: 2_500, rateGoal: F.rate(-1.5))
        let adoption = TargetAdoption(calculated: calculated, macros: F.macros(), formula: .builtinV1)
        let outcome = try TargetLedger().adopting(adoption, on: F.noon(30), calendar: F.utc, id: F.uuid(1))

        #expect(outcome.warnings == [.targetBelowFloor, .rateAboveLimit])
        #expect(outcome.ledger.periods.count == 1)
        #expect(outcome.ledger.openPeriod == outcome.period)
        #expect(outcome.period.adoptedTargetKcal == 850)
        #expect(outcome.period.calculatedTargetKcal == 850)
        #expect(outcome.period.expenditureAtAdoptionKcal == 2_500)

        // Saved: survives an encode/decode round trip unchanged.
        let decoded = try JSONDecoder().decode(TargetLedger.self, from: F.bytes(outcome.ledger))
        #expect(decoded == outcome.ledger)
    }

    @Test("adoption checks the adopted number: adjusting 1300 down to 1100 warns")
    func adjustedBelowFloor() throws {
        let calculated = CalculatedTarget(expenditureKcal: 1_850, rateGoal: F.rate(-0.5))
        #expect(calculated.kcalPerDay == 1_300)
        #expect(calculated.warnings.isEmpty)
        let adoption = TargetAdoption(
            calculated: calculated, adoptedTargetKcal: 1_100, macros: F.macros(), formula: .builtinV1
        )
        let outcome = try TargetLedger().adopting(adoption, on: F.noon(30), calendar: F.utc, id: F.uuid(1))
        #expect(outcome.warnings == [.targetBelowFloor])
        #expect(outcome.period.adoptedTargetKcal == 1_100)
        #expect(outcome.period.calculatedTargetKcal == 1_300)
    }

    @Test("adoption keeps the calculated target's warning: adjusting 1100 up to 1300 still warns")
    func calculatedBelowFloorAdjustedUp() throws {
        let calculated = CalculatedTarget(expenditureKcal: 1_650, rateGoal: F.rate(-0.5))
        #expect(calculated.kcalPerDay == 1_100)
        #expect(calculated.warnings == [.targetBelowFloor])
        let adoption = TargetAdoption(
            calculated: calculated, adoptedTargetKcal: 1_300, macros: F.macros(), formula: .builtinV1
        )
        let outcome = try TargetLedger().adopting(adoption, on: F.noon(30), calendar: F.utc, id: F.uuid(1))
        #expect(outcome.warnings == [.targetBelowFloor])
        #expect(outcome.period.adoptedTargetKcal == 1_300)
        #expect(outcome.period.calculatedTargetKcal == 1_100)
    }
}

@Suite("Macro targets (spec §3 \"Adopted target\")")
struct MacroTargetTests {
    @Test("suggestion: protein = 1.6 g × trend kg, fat floor 20%")
    func suggestion() throws {
        let at80 = try #require(MacroTargets.suggested(trendKg: 80))
        #expect(at80.proteinTargetG == 128)
        #expect(at80.fatFloorPct == 20)

        let atFixtureTrend = try #require(MacroTargets.suggested(trendKg: 78.1875))
        #expect(abs(atFixtureTrend.proteinTargetG - 125.1) < 1e-9)
    }

    @Test("no suggestion without a defined, positive trend", arguments: [nil, 0, -1, .nan] as [Double?])
    func noSuggestion(trendKg: Double?) {
        #expect(MacroTargets.suggested(trendKg: trendKg) == nil)
    }

    @Test("carbs are the remainder: 2000 kcal, 128 g protein, 20% fat floor")
    func remainder() {
        let split = F.macros().breakdown(targetKcal: 2_000)
        #expect(split.proteinKcal == 512)
        #expect(split.fatFloorKcal == 400)
        #expect(abs(split.fatFloorG - 400.0 / 9) < 1e-12)
        #expect(split.carbsKcal == 1_088)
        #expect(split.carbsG == 272)
        #expect(split.overCommittedKcal == 0)
    }

    @Test("protein + fat floor above the target: carbs 0, excess reported")
    func overCommitted() {
        let split = F.macros(protein: 200, fatFloorPct: 30).breakdown(targetKcal: 1_000)
        #expect(split.carbsG == 0)
        #expect(split.carbsKcal == 0)
        #expect(split.overCommittedKcal == 100)
    }

    @Test("invalid macro inputs are rejected")
    func validation() {
        #expect(MacroTargets(proteinTargetG: -1) == nil)
        #expect(MacroTargets(proteinTargetG: .nan) == nil)
        #expect(MacroTargets(proteinTargetG: 100, fatFloorPct: 101) == nil)
        #expect(MacroTargets(proteinTargetG: 100, fatFloorPct: -1) == nil)
        #expect(MacroTargets(proteinTargetG: 100, fatFloorPct: 0) != nil)
    }
}
