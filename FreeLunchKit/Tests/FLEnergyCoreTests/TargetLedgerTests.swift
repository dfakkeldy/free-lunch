// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLEnergyCore

// Expected values were computed by hand and with a throwaway script outside
// the repo from the spec §3 formula text, not from this module's output.

private typealias F = TargetFixture

/// The live calculated target for day T at rate −0.5 kg/wk under v1.
private func liveTarget(on offset: Int, intake: [DayIntake]) throws -> CalculatedTarget {
    let estimate = try #require(EnergyFormulaVersion.builtinV1.evaluate(
        on: F.noon(offset), intake: intake, weights: F.weights, calendar: F.utc
    ).estimate)
    return CalculatedTarget(estimate: estimate, rateGoal: F.rate(-0.5))
}

@Suite("Adoption: explicit, closes the open period, pins values (spec §3)")
struct AdoptionTests {
    @Test("adopting pins expenditure, calculated, adjusted adopted target, macros and formula")
    func pinsValues() throws {
        let calculated = try liveTarget(on: 30, intake: F.intake())
        #expect(calculated.kcalPerDay == 1_931.25)
        let adoption = TargetAdoption(
            calculated: calculated, adoptedTargetKcal: 1_950, macros: F.macros(protein: 125), formula: .builtinV1
        )
        let outcome = try TargetLedger().adopting(adoption, on: F.noon(30), calendar: F.utc, id: F.uuid(7))
        let period = outcome.period

        #expect(period.id == F.uuid(7))
        #expect(period.startDate == F.day(30))
        #expect(period.endDate == nil)
        #expect(period.expenditureAtAdoptionKcal == 2_481.25)
        #expect(period.calculatedTargetKcal == 1_931.25)
        #expect(period.adoptedTargetKcal == 1_950)
        #expect(period.proteinTargetG == 125)
        #expect(period.fatFloorPct == 20)
        #expect(period.formula == .builtinV1)
        #expect(outcome.warnings.isEmpty)
    }

    @Test("without an adjustment the adopted target equals the calculated one")
    func defaultAdoptedEqualsCalculated() throws {
        let calculated = try liveTarget(on: 30, intake: F.intake())
        let adoption = TargetAdoption(calculated: calculated, macros: F.macros(), formula: .builtinV1)
        #expect(adoption.adoptedTargetKcal == 1_931.25)
    }

    @Test("a second adoption closes the open period with endDate = yesterday")
    func closesOpenPeriod() throws {
        let first = try TargetLedger().adopting(
            TargetAdoption(calculated: try liveTarget(on: 21, intake: F.intake()), macros: F.macros(), formula: .builtinV1),
            on: F.noon(21), calendar: F.utc, id: F.uuid(1)
        )
        let second = try first.ledger.adopting(
            TargetAdoption(calculated: try liveTarget(on: 30, intake: F.intake()), adoptedTargetKcal: 1_900,
                           macros: F.macros(), formula: .builtinV1),
            on: F.morning(30), calendar: F.utc, id: F.uuid(2)
        )

        #expect(second.ledger.periods.count == 2)
        let closed = second.ledger.periods[0]
        #expect(closed.id == F.uuid(1))
        #expect(closed.endDate == F.day(29))
        // Closing sets the end date and nothing else.
        #expect(closed.startDate == first.period.startDate)
        #expect(closed.adoptedTargetKcal == first.period.adoptedTargetKcal)
        #expect(closed.calculatedTargetKcal == first.period.calculatedTargetKcal)
        #expect(closed.expenditureAtAdoptionKcal == first.period.expenditureAtAdoptionKcal)
        #expect(closed.formula == first.period.formula)

        #expect(second.ledger.openPeriod?.id == F.uuid(2))
        #expect(second.ledger.period(governing: F.noon(29), calendar: F.utc)?.id == F.uuid(1))
        #expect(second.ledger.period(governing: F.noon(30), calendar: F.utc)?.id == F.uuid(2))
        #expect(second.ledger.period(governing: F.noon(20), calendar: F.utc) == nil)
        // The ledger the adoption started from is untouched.
        #expect(first.ledger.periods == [first.period])
    }

    @Test("same-day re-adoption keeps the first as a record that governs no day")
    func sameDayReadoption() throws {
        let calculated = try liveTarget(on: 30, intake: F.intake())
        let first = try TargetLedger().adopting(
            TargetAdoption(calculated: calculated, macros: F.macros(), formula: .builtinV1),
            on: F.noon(30), calendar: F.utc, id: F.uuid(1)
        )
        let second = try first.ledger.adopting(
            TargetAdoption(calculated: calculated, adoptedTargetKcal: 1_900, macros: F.macros(), formula: .builtinV1),
            on: F.noon(30), calendar: F.utc, id: F.uuid(2)
        )
        #expect(second.ledger.periods.map(\.id) == [F.uuid(1), F.uuid(2)])
        #expect(second.ledger.periods[0].endDate == F.day(29))
        #expect(second.ledger.period(governing: F.noon(30), calendar: F.utc)?.id == F.uuid(2))
        #expect(second.ledger.period(governing: F.noon(29), calendar: F.utc) == nil)
    }

    @Test("adoption before the open period's start is refused")
    func precedesOpenPeriod() throws {
        let calculated = try liveTarget(on: 30, intake: F.intake())
        let adoption = TargetAdoption(calculated: calculated, macros: F.macros(), formula: .builtinV1)
        let ledger = try TargetLedger().adopting(adoption, on: F.noon(30), calendar: F.utc, id: F.uuid(1)).ledger
        #expect(throws: TargetLedger.AdoptionError.precedesOpenPeriod(openPeriodStart: F.day(30))) {
            try ledger.adopting(adoption, on: F.noon(29), calendar: F.utc, id: F.uuid(2))
        }
    }

    @Test("a non-finite or non-positive adopted number is refused", arguments: [0, -100, Double.nan, .infinity])
    func invalidAdoptedTarget(kcal: Double) throws {
        let calculated = try liveTarget(on: 30, intake: F.intake())
        let adoption = TargetAdoption(
            calculated: calculated, adoptedTargetKcal: kcal, macros: F.macros(), formula: .builtinV1
        )
        #expect(throws: TargetLedger.AdoptionError.invalidAdoptedTarget) {
            try TargetLedger().adopting(adoption, on: F.noon(30), calendar: F.utc, id: F.uuid(1))
        }
    }

    @Test("suggest-only is the default adoption mode")
    func defaultMode() {
        #expect(AdoptionMode.default == .suggestOnly)
    }
}

@Suite("Adopted-target immutability (spec §3 acceptance #4)")
struct AdoptedTargetImmutabilityTests {
    @Test("backfill edits change expenditure and calculated target, but no field of any period")
    func backfillDoesNotTouchPeriods() throws {
        // Two periods: one closed (adopted day 21), one open (adopted day 30).
        let original = F.intake()
        let first = try TargetLedger().adopting(
            TargetAdoption(calculated: try liveTarget(on: 21, intake: original), macros: F.macros(), formula: .builtinV1),
            on: F.noon(21), calendar: F.utc, id: F.uuid(1)
        )
        let ledger = try first.ledger.adopting(
            TargetAdoption(calculated: try liveTarget(on: 30, intake: original), adoptedTargetKcal: 1_950,
                           macros: F.macros(), formula: .builtinV1),
            on: F.noon(30), calendar: F.utc, id: F.uuid(2)
        ).ledger
        let periodsBefore = ledger.periods
        let bytesBefore = try F.bytes(ledger)

        // Backfill edit: day 15 corrected from 2000 to 4520 kcal. Mean intake
        // over days 9–29 becomes 2120, so expenditure 2601.25 and the
        // calculated target (−0.5 kg/wk) 2051.25 — both changed.
        let edited = F.intake(edits: [15: 4_520])
        let before = try liveTarget(on: 30, intake: original)
        let after = try liveTarget(on: 30, intake: edited)
        #expect(before.expenditureKcal == 2_481.25)
        #expect(after.expenditureKcal == 2_601.25)
        #expect(before.kcalPerDay == 1_931.25)
        #expect(after.kcalPerDay == 2_051.25)

        // The recalculation surfaces a suggestion (drift 101.25 kcal) …
        let suggestion = try #require(ledger.readoptionSuggestion(live: after))
        #expect(suggestion.driftKcal == 101.25)
        #expect(suggestion.adoptedTargetKcal == 1_950)

        // … and re-renders history, which is derived …
        let rendered = EnergyHistory.render(
            ledger: ledger, through: F.day(35), intake: edited, weights: F.weights, calendar: F.utc
        )
        #expect(rendered.map(\.period) == periodsBefore)

        // … but every field of every period is exactly as adopted.
        #expect(ledger.periods == periodsBefore)
        #expect(try F.bytes(ledger) == bytesBefore)
        #expect(ledger.periods[1].expenditureAtAdoptionKcal == 2_481.25)
        #expect(ledger.periods[1].calculatedTargetKcal == 1_931.25)
        #expect(ledger.periods[1].adoptedTargetKcal == 1_950)
        #expect(ledger.periods[0].endDate == F.day(29))
    }
}

@Suite("Re-adoption suggestion: ≥5% or ≥100 kcal drift (spec §3)")
struct ReadoptionSuggestionTests {
    @Test(
        "thresholds are inclusive and either one suffices",
        arguments: [
            (2_000.0, 2_099.0, false), // 99 kcal, 4.95%
            (2_000.0, 2_100.0, true),  // 100 kcal
            (2_000.0, 1_900.0, true),  // −100 kcal
            (1_500.0, 1_574.0, false), // 74 kcal, 4.93%
            (1_500.0, 1_575.0, true),  // 75 kcal = 5% exactly
            (1_500.0, 1_425.0, true),  // −5% exactly
            (1_500.0, 1_580.0, true),  // 80 kcal, 5.33%
            (2_000.0, 2_000.0, false)
        ]
    )
    func thresholds(adopted: Double, live: Double, suggests: Bool) {
        let suggestion = ReadoptionSuggestion.evaluate(adoptedTargetKcal: adopted, calculatedTargetKcal: live)
        #expect((suggestion != nil) == suggests)
        if let suggestion {
            #expect(suggestion.driftKcal == live - adopted)
        }
    }

    @Test("small backfill drift stays quiet; no open period means no suggestion")
    func ledgerSuggestion() throws {
        let calculated = try liveTarget(on: 30, intake: F.intake())
        let ledger = try TargetLedger().adopting(
            TargetAdoption(calculated: calculated, adoptedTargetKcal: 1_950, macros: F.macros(), formula: .builtinV1),
            on: F.noon(30), calendar: F.utc, id: F.uuid(1)
        ).ledger
        // Day 15 → 2420: mean 2020, calculated 1951.25, drift 1.25 kcal.
        let small = try liveTarget(on: 30, intake: F.intake(edits: [15: 2_420]))
        #expect(small.kcalPerDay == 1_951.25)
        #expect(ledger.readoptionSuggestion(live: small) == nil)
        #expect(TargetLedger().readoptionSuggestion(live: small) == nil)
    }
}
