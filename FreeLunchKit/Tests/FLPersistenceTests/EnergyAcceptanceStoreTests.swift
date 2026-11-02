// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §3 acceptance #4 and #5, re-run against the SwiftData store: meals,
// formula versions and TargetPeriods are stored rows, read back through the
// public API (and from a reopened store file), not in-memory values.
//
// Expected values are in EnergyStoreFixture.swift's header; the backfill
// figures are derived there the same way (by hand and with a throwaway
// script outside the repo).
import FLCore
import FLEnergyCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

private typealias E = EnergyStoreFixture

/// A store file holding the fixture's meals and both formula versions'
/// rows, plus the URL to reopen it with.
@MainActor
private func seededStore(registerV2: Bool = true) throws -> (store: SwiftDataStore, url: URL) {
    let url = try temporaryStoreURL()
    let store = try SwiftDataStore.phone(at: .file(url))
    try E.logMeals(store)
    try store.registerFormulaVersion(E.v1Row)
    if registerV2 { try store.registerFormulaVersion(E.v2Row) }
    return (store, url)
}

/// Adopts the live calculated target on `offset` under `formula`, reading
/// intake from the store.
@MainActor
@discardableResult
private func adopt(
    _ store: SwiftDataStore,
    on offset: Int,
    formula: EnergyFormulaVersion,
    adjustedTo adopted: Double? = nil,
    id: UUID
) throws -> AdoptionOutcome {
    let schedule = FormulaActivationSchedule(initial: formula)
    let live = try EnergyBinding.recompute(
        store: store, today: E.noon(offset), historyFrom: E.day(offset), weights: E.weights,
        schedule: schedule, rateGoal: E.rate(-0.5), calendar: E.calendar
    )
    let calculated = try #require(live.calculatedTarget)
    return try store.adoptTarget(
        TargetAdoption(calculated: calculated, adoptedTargetKcal: adopted, macros: E.macros(), formula: formula),
        on: E.noon(offset), calendar: E.calendar, id: id
    )
}

@MainActor
private func renderedLedger(_ store: SwiftDataStore, through offset: Int) throws -> [RenderedTargetPeriod] {
    EnergyHistory.render(
        ledger: try store.targetLedger(),
        through: E.day(offset),
        intake: try store.dayIntakes(from: E.day(-30), through: E.day(offset), calendar: E.calendar),
        weights: E.weights,
        calendar: E.calendar
    )
}

@MainActor
@Suite("Spec §3 acceptance #4 against the store: adopted-target immutability")
struct StoreAdoptedTargetImmutabilityTests {
    @Test("a backfill edit moves expenditure and the calculated target but no field of any stored TargetPeriod")
    func backfillLeavesPeriodsUntouched() throws {
        let (store, url) = try seededStore()
        defer { removeStore(at: url) }

        // Two periods: one closed, one open (adjusted to 1900 so the three
        // pinned values all differ).
        try adopt(store, on: 21, formula: .builtinV1, id: uid(1))
        let outcome = try adopt(store, on: 25, formula: .builtinV1, adjustedTo: 1_900, id: uid(2))
        #expect(outcome.warnings.isEmpty)

        // The stored periods, field by field (hand-computed values).
        let ledger = try store.targetLedger()
        #expect(ledger.periods.count == 2)
        let closed = ledger.periods[0]
        #expect(closed.id == uid(1))
        #expect(closed.startDate == E.day(21))
        #expect(closed.endDate == E.day(24))
        #expect(closed.expenditureAtAdoptionKcal == 2_481.25)
        #expect(closed.calculatedTargetKcal == 1_931.25)
        #expect(closed.adoptedTargetKcal == 1_931.25)
        let open = ledger.periods[1]
        #expect(open.id == uid(2))
        #expect(open.startDate == E.day(25))
        #expect(open.endDate == nil)
        #expect(open.expenditureAtAdoptionKcal == 2_481.25)
        #expect(open.calculatedTargetKcal == 1_931.25)
        #expect(open.adoptedTargetKcal == 1_900)
        #expect(open.proteinTargetG == 128)
        #expect(open.fatFloorPct == 20)
        #expect(open.formula == .builtinV1)

        let ledgerBytes = try E.bytes(ledger)
        let schedule = FormulaActivationSchedule()
        let before = try EnergyBinding.recompute(
            store: store, today: E.noon(25), historyFrom: E.day(21), weights: E.weights,
            schedule: schedule, rateGoal: E.rate(-0.5), calendar: E.calendar
        )
        #expect(before.today?.displayedKcalPerDay == 2_481.25)
        #expect(before.calculatedTarget?.kcalPerDay == 1_931.25)
        // Drift 31.25 kcal: under 100 kcal and under 5% of 1900 (95).
        #expect(before.readoptionSuggestion == nil)

        // Backfill: a forgotten 2100 kcal added to day 10's logged plate
        // (inside day 25's window, days 4–24). Mean intake 2000 → 2100.
        try store.addItem(
            .adHoc(id: uid(7_001), name: "Forgotten snack", quantity: Grams(400), nutrition: E.kcal(2_100)),
            toMeal: E.mealID(10)
        )
        let after = try EnergyBinding.recompute(
            store: store, today: E.noon(25), historyFrom: E.day(21), weights: E.weights,
            schedule: schedule, rateGoal: E.rate(-0.5), calendar: E.calendar
        )
        #expect(EnergyRecomputeReason.reasons(from: before.key, to: after.key) == [.intakeChanged])
        #expect(after.today?.displayedKcalPerDay == 2_581.25)
        #expect(after.calculatedTarget?.expenditureKcal == 2_581.25)
        #expect(after.calculatedTarget?.kcalPerDay == 2_031.25)
        // Drift 2031.25 − 1900 = 131.25 ≥ 100: the quiet suggestion appears.
        #expect(after.readoptionSuggestion?.driftKcal == 131.25)
        #expect(after.readoptionSuggestion?.adoptedTargetKcal == 1_900)

        // The derived history moved (days 21–24 all have day 10 in their
        // window too)...
        let rendered = try renderedLedger(store, through: 25)
        #expect(rendered.flatMap(\.history.days).allSatisfy { $0.displayedKcalPerDay == 2_581.25 })
        // ...and the stored periods did not, by value and byte for byte.
        #expect(try store.targetLedger() == ledger)
        #expect(try E.bytes(store.targetLedger()) == ledgerBytes)

        // A second backfill edit (removing the item) moves the numbers back;
        // the periods are still untouched.
        try store.removeItem(id: uid(7_001))
        let reverted = try EnergyBinding.recompute(
            store: store, today: E.noon(25), historyFrom: E.day(21), weights: E.weights,
            schedule: schedule, rateGoal: E.rate(-0.5), calendar: E.calendar
        )
        #expect(reverted.calculatedTarget?.kcalPerDay == 1_931.25)
        #expect(try E.bytes(store.targetLedger()) == ledgerBytes)

        // A late-logged backfill plate on a day with nothing yet: same rule.
        try store.createMeal(MealEntryData(id: uid(7_100), createdAt: E.noon(26), source: .phone))
        try store.addItem(
            .adHoc(id: uid(7_101), name: "Late plate", quantity: Grams(300), nutrition: E.kcal(500)),
            toMeal: uid(7_100)
        )
        try store.logMeal(id: uid(7_100), at: E.noon(12))
        #expect(try E.bytes(store.targetLedger()) == ledgerBytes)

        // A weight correction changes the series the engine reads; the
        // recomputation reports it and the periods are still untouched.
        let corrected = TrendSeries(
            smoothing: .standard,
            points: E.weights.points.map {
                $0.measuredAt == E.morning(24)
                    ? TrendPoint(measuredAt: $0.measuredAt, weightKg: 78.25, trendKg: 78.25)
                    : $0
            }
        )
        let afterCorrection = try EnergyBinding.recompute(
            store: store, today: E.noon(25), historyFrom: E.day(21), weights: corrected,
            schedule: schedule, rateGoal: E.rate(-0.5), calendar: E.calendar
        )
        #expect(EnergyRecomputeReason.reasons(from: reverted.key, to: afterCorrection.key).contains(.weightChanged))
        #expect(afterCorrection.calculatedTarget?.kcalPerDay != reverted.calculatedTarget?.kcalPerDay)
        #expect(try E.bytes(store.targetLedger()) == ledgerBytes)

        // Durable: a cold reopen of the file reads the same bytes.
        let reopened = try SwiftDataStore.phone(at: .file(url))
        #expect(try E.bytes(reopened.targetLedger()) == ledgerBytes)
    }

    @Test("re-adopting after a backfill closes the open row (end date only) and pins the new numbers")
    func readoptAfterBackfill() throws {
        let (store, url) = try seededStore()
        defer { removeStore(at: url) }
        try adopt(store, on: 25, formula: .builtinV1, adjustedTo: 1_900, id: uid(1))
        let original = try #require(try store.targetLedger().openPeriod)

        try store.addItem(
            .adHoc(id: uid(7_001), name: "Forgotten snack", quantity: Grams(400), nutrition: E.kcal(2_100)),
            toMeal: E.mealID(10)
        )
        try adopt(store, on: 27, formula: .builtinV1, id: uid(2))

        let ledger = try store.targetLedger()
        #expect(ledger.periods.count == 2)
        let closed = ledger.periods[0]
        #expect(closed.endDate == E.day(26))
        // Every pinned field is the original's.
        #expect(closed.id == original.id)
        #expect(closed.startDate == original.startDate)
        #expect(closed.expenditureAtAdoptionKcal == 2_481.25)
        #expect(closed.calculatedTargetKcal == 1_931.25)
        #expect(closed.adoptedTargetKcal == 1_900)
        #expect(closed.proteinTargetG == original.proteinTargetG)
        #expect(closed.fatFloorPct == original.fatFloorPct)
        #expect(closed.formula == original.formula)
        // Day 27's window is days 6–26, still containing day 10.
        let reopened = ledger.periods[1]
        #expect(reopened.startDate == E.day(27))
        #expect(reopened.expenditureAtAdoptionKcal == 2_581.25)
        #expect(reopened.calculatedTargetKcal == 2_031.25)
        #expect(reopened.adoptedTargetKcal == 2_031.25)
    }
}

@MainActor
@Suite("Spec §3 acceptance #5 against the store: version pinning")
struct StoreVersionPinningTests {
    @Test("activating a new version leaves prior stored periods and their rendered history byte-identical")
    func activationLeavesPriorPeriodsByteIdentical() throws {
        let (store, url) = try seededStore(registerV2: false)
        defer { removeStore(at: url) }
        try adopt(store, on: 21, formula: .builtinV1, id: uid(1))
        try adopt(store, on: 25, formula: .builtinV1, id: uid(2))

        let ledgerBefore = try E.bytes(store.targetLedger())
        let renderedBefore = try renderedLedger(store, through: 27)
        let renderedBytesBefore = try E.bytes(renderedBefore)
        // Hand-computed: periods cover days 21–24 and 25–27, all v1 at 2481.25.
        #expect(renderedBefore.map { $0.history.days.count } == [4, 3])
        #expect(renderedBefore.flatMap(\.history.days).allSatisfy {
            $0.formulaName == "FL-EB v1" && $0.displayedKcalPerDay == 2_481.25 && $0.state == .tracking
        })

        // Activation: the new version's row is written to the store, and the
        // schedule (a setting) moves forward from day 28.
        try store.registerFormulaVersion(E.v2Row)
        let schedule = try FormulaActivationSchedule().activating(E.v2, from: E.noon(28), calendar: E.calendar)

        #expect(try E.bytes(store.targetLedger()) == ledgerBefore)
        #expect(try E.bytes(renderedLedger(store, through: 27)) == renderedBytesBefore)
        let reopened = try SwiftDataStore.phone(at: .file(url))
        #expect(try E.bytes(reopened.targetLedger()) == ledgerBefore)
        #expect(try E.bytes(renderedLedger(reopened, through: 27)) == renderedBytesBefore)

        // Forward days use the new math: the live series from the store
        // switches to v2 on day 28 and not before.
        let live = try EnergyBinding.recompute(
            store: store, today: E.noon(30), historyFrom: E.day(21), weights: E.weights,
            schedule: schedule, rateGoal: E.rate(-0.5), calendar: E.calendar
        )
        #expect(live.history.label == .asRecorded)
        #expect(live.history.days.count == 10)
        let past = Array(live.history.days.prefix(7))
        let forward = Array(live.history.days.dropFirst(7))
        #expect(try E.bytes(past) == E.bytes(renderedBefore.flatMap(\.history.days)))
        #expect(forward.map(\.day) == [E.day(28), E.day(29), E.day(30)])
        #expect(forward.allSatisfy { $0.formulaName == "FL-EB v2 (synthetic)" && $0.displayedKcalPerDay == 2_437.5 })
        #expect(live.calculatedTarget?.kcalPerDay == 1_937.5)
        #expect(live.calculatedTarget?.energyDensityKcalPerKg == 7_000)
        // Drift against the open v1 period (1931.25) is 6.25: no suggestion.
        #expect(live.readoptionSuggestion == nil)

        // The open period, adopted under v1, still renders with v1 on days
        // after the activation, though the live series has moved to v2.
        let openPeriod = try #require(try store.targetLedger().openPeriod)
        let pinned = EnergyHistory.render(
            period: openPeriod, through: E.day(30),
            intake: live.key.intake, weights: E.weights, calendar: E.calendar
        )
        #expect(pinned.history.days.count == 6) // days 25–30
        #expect(pinned.history.days.allSatisfy { $0.formulaName == "FL-EB v1" && $0.displayedKcalPerDay == 2_481.25 })

        // Adopting on day 30 under the active version pins v2's row; the v1
        // periods keep theirs.
        let outcome = try store.adoptTarget(
            TargetAdoption(calculated: try #require(live.calculatedTarget), macros: E.macros(), formula: schedule.latest),
            on: E.noon(30), calendar: E.calendar, id: uid(3)
        )
        #expect(outcome.period.formula == E.v2)
        let ledger = try store.targetLedger()
        #expect(ledger.periods.map(\.formula) == [.builtinV1, .builtinV1, E.v2])
        #expect(ledger.periods[1].endDate == E.day(29))
        #expect(ledger.periods[2].expenditureAtAdoptionKcal == 2_437.5)
        #expect(ledger.periods[2].calculatedTargetKcal == 1_937.5)
        let renderedAfter = try renderedLedger(store, through: 30)
        #expect(try E.bytes(renderedAfter[0]) == E.bytes(renderedBefore[0]))
        #expect(renderedAfter.map { $0.history.days.count } == [4, 5, 1])
        #expect(renderedAfter[1].history.days.allSatisfy { $0.formulaName == "FL-EB v1" && $0.displayedKcalPerDay == 2_481.25 })
        #expect(renderedAfter[2].history.days.allSatisfy { $0.formulaName == "FL-EB v2 (synthetic)" && $0.displayedKcalPerDay == 2_437.5 })

        // The stored rows really reference distinct version rows.
        let rows = try store.context.fetch(FetchDescriptor<TargetPeriod>())
        let pins = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.formulaVersion?.id) })
        #expect(pins == [uid(1): E.v1Row.id, uid(2): E.v1Row.id, uid(3): E.v2Row.id])
    }

    @Test("re-run history carries the reconstructed label and changes nothing stored")
    func rerunIsReconstructed() throws {
        let (store, url) = try seededStore()
        defer { removeStore(at: url) }
        try adopt(store, on: 21, formula: .builtinV1, id: uid(1))
        let ledgerBefore = try E.bytes(store.targetLedger())
        let formulasBefore = try store.formulaVersions()

        let intake = try store.dayIntakes(from: E.day(-30), through: E.day(27), calendar: E.calendar)
        let rerun = EnergyHistory.rerun(
            with: E.v2, from: E.day(21), through: E.day(27),
            intake: intake, weights: E.weights, calendar: E.calendar
        )
        #expect(rerun.label == .reconstructed)
        #expect(rerun.isReconstructed)
        #expect(rerun.days.count == 7)
        #expect(rerun.days.allSatisfy { $0.formulaName == "FL-EB v2 (synthetic)" && $0.displayedKcalPerDay == 2_437.5 })

        // The as-recorded rendering of the stored period is not reconstructed
        // and still shows v1.
        let recorded = try renderedLedger(store, through: 27)
        #expect(recorded.allSatisfy { $0.history.label == .asRecorded })
        #expect(recorded[0].history.days.allSatisfy { $0.formulaName == "FL-EB v1" && $0.displayedKcalPerDay == 2_481.25 })

        #expect(try E.bytes(store.targetLedger()) == ledgerBefore)
        #expect(try store.formulaVersions() == formulasBefore)
    }
}
