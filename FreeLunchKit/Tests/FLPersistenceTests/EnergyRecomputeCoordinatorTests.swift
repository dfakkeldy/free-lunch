// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §3 "Recompute" and spec §6 acceptance #3: marking a day "didn't
// track" and changing α each recompute the energy series, once. The count
// comes from a seam inside the coordinator (the injected compute), not from
// the call sites.
//
// Fixture (synthetic): a logged 2000 kcal plate on days 0...40, plus a
// 3000 kcal extra plate on day 10; raw weigh-ins of 80 − 0.0625·k kg at
// 07:00 on days −22...40, stored as mirrored HealthKit samples so the trend
// is built from the store with the persisted α. Today is day 25: the window
// is days 4...24, all intake-complete.
import FLCore
import FLEnergyCore
import Foundation
import Testing
@testable import FLPersistence

private typealias E = EnergyStoreFixture

/// Counts engine runs through the coordinator's compute seam.
@MainActor
private final class RecomputeCounter {
    private(set) var keys: [EnergyRecomputeKey] = []
    var count: Int { keys.count }

    func record(_ key: EnergyRecomputeKey) { keys.append(key) }
}

@MainActor
private func makeFixtureStore(at location: FreeLunchStoreLocation = .inMemory) throws -> SwiftDataStore {
    let store = try SwiftDataStore.phone(at: location)
    try E.logMeals(store)
    try store.createMeal(MealEntryData(
        id: uid(7_010),
        state: .logged,
        createdAt: E.day(10).addingTimeInterval(20 * 3_600),
        loggedAt: E.day(10).addingTimeInterval(20 * 3_600),
        items: [
            MealItemData(
                id: uid(7_011), order: 0, foodID: nil, adHocName: "Synthetic extra",
                quantity: Grams(300), nutrition: E.kcal(3_000), provenance: .typed
            )
        ],
        source: .phone
    ))
    for k in -22...40 {
        try store.upsertWeightSample(WeightSampleData(
            hkUUID: uid(8_000 + k + 100), measuredAt: E.morning(k),
            weight: Kilograms(80 - 0.0625 * Double(k)), sourceBundleID: "com.example.synthetic.scale"
        ))
    }
    return store
}

@MainActor
private func makeCoordinator(
    _ store: SwiftDataStore,
    counter: RecomputeCounter
) -> EnergyRecomputeCoordinator<SwiftDataStore> {
    EnergyRecomputeCoordinator(
        store: store, calendar: E.calendar, today: E.noon(25), historyFrom: E.day(21),
        compute: { key in
            counter.record(key)
            return try EnergyBinding.recompute(store: store, key: key, calendar: E.calendar)
        }
    )
}

@MainActor
@Suite("Energy recompute coordinator: settings changes recompute once")
struct EnergyRecomputeCoordinatorTests {
    @Test("the first refresh computes once; an unchanged second refresh computes nothing")
    func firstRun() throws {
        let store = try makeFixtureStore()
        let counter = RecomputeCounter()
        let coordinator = makeCoordinator(store, counter: counter)
        #expect(coordinator.latest == nil)

        let first = try coordinator.refresh()
        #expect(counter.count == 1)
        #expect(coordinator.latest == first)
        // Defaults flow through: α 0.10, maintenance, builtin formula.
        #expect(first.key.weights.smoothing == .standard)
        #expect(first.key.rateGoal == .maintenance)
        #expect(first.key.schedule == FormulaActivationSchedule())

        _ = try coordinator.refresh()
        #expect(counter.count == 1)
    }

    @Test("marking a day didn't-track recomputes the series exactly once and moves the estimate")
    func markDay() throws {
        let store = try makeFixtureStore()
        let counter = RecomputeCounter()
        let coordinator = makeCoordinator(store, counter: counter)
        let before = try coordinator.refresh()
        #expect(counter.count == 1)
        let beforeEstimate = try #require(before.evaluation.estimate)
        // Day 10 carries 5000 kcal: (20 × 2000 + 5000) / 21.
        #expect(abs(beforeEstimate.meanIntakeKcal - 45_000.0 / 21) < 1e-9)
        #expect(beforeEstimate.completeIntakeDays == 21)

        let after = try coordinator.markDidNotTrack(day: E.noon(10))
        #expect(counter.count == 2)
        let afterEstimate = try #require(after.evaluation.estimate)
        #expect(afterEstimate.completeIntakeDays == 20)
        #expect(afterEstimate.meanIntakeKcal == 2_000)
        #expect(afterEstimate.kcalPerDay != beforeEstimate.kcalPerDay)
        #expect(after.key.intake.first { $0.day == E.day(10) }?.evidence.markedDidNotTrack == true)
        #expect(EnergyRecomputeReason.reasons(from: before.key, to: after.key) == [.intakeChanged])

        // Marking it again changes no input: no recompute.
        _ = try coordinator.markDidNotTrack(day: E.morning(10))
        #expect(counter.count == 2)

        // Removing the mark is another input change: one more.
        let restored = try coordinator.unmarkDidNotTrack(day: E.day(10))
        #expect(counter.count == 3)
        #expect(restored.evaluation == before.evaluation)
        _ = try coordinator.unmarkDidNotTrack(day: E.day(10))
        #expect(counter.count == 3)
    }

    @Test("changing α recomputes the series exactly once, from the new α")
    func changeAlpha() throws {
        let store = try makeFixtureStore()
        let counter = RecomputeCounter()
        let coordinator = makeCoordinator(store, counter: counter)
        let before = try coordinator.refresh()
        let beforeEstimate = try #require(before.evaluation.estimate)

        let after = try coordinator.setTrendAlpha(0.25)
        #expect(counter.count == 2)
        #expect(after.key.weights.smoothing.alpha == 0.25)
        #expect(counter.keys.last?.weights.smoothing.alpha == 0.25)
        #expect(try store.energySettings().smoothing.alpha == 0.25)
        let reasons = EnergyRecomputeReason.reasons(from: before.key, to: after.key)
        #expect(reasons.contains(.smoothingChanged))
        #expect(!reasons.contains(.intakeChanged))

        // The result is the engine's output for an independently smoothed
        // series, and it differs from the α = 0.10 one.
        let samples = try store.correctedWeightView().map { WeightSample(measuredAt: $0.measuredAt, weightKg: $0.weightKg) }
        let independent = try EnergyBinding.recompute(
            store: store, today: E.noon(25), historyFrom: E.day(21),
            weights: TrendWeight.series(samples: samples, smoothing: try #require(TrendSmoothing(alpha: 0.25))),
            schedule: FormulaActivationSchedule(), rateGoal: .maintenance, calendar: E.calendar
        )
        #expect(after.evaluation == independent.evaluation)
        let afterEstimate = try #require(after.evaluation.estimate)
        #expect(afterEstimate.trendDeltaKg != beforeEstimate.trendDeltaKg)
        #expect(afterEstimate.kcalPerDay != beforeEstimate.kcalPerDay)

        // The same α again, or a value outside the range, runs nothing.
        _ = try coordinator.setTrendAlpha(0.25)
        #expect(counter.count == 2)
        #expect(throws: EnergySettingsError.alphaOutOfRange(0.26)) { try coordinator.setTrendAlpha(0.26) }
        #expect(counter.count == 2)
        #expect(try store.energySettings().smoothing.alpha == 0.25)
        #expect(coordinator.latest == after)
    }

    @Test("a rate goal or a formula activation each recompute once; the adoption mode feeds no recompute")
    func otherSettings() throws {
        let store = try makeFixtureStore()
        let counter = RecomputeCounter()
        let coordinator = makeCoordinator(store, counter: counter)
        let base = try coordinator.refresh()

        let rated = try coordinator.setRateGoal(kgPerWeek: -0.5)
        #expect(counter.count == 2)
        let baseTarget = try #require(base.calculatedTarget)
        let ratedTarget = try #require(rated.calculatedTarget)
        #expect(abs((baseTarget.kcalPerDay - ratedTarget.kcalPerDay) - 550) < 1e-9)

        // Activating from today: today runs under v2 (ρ 7000), the days
        // before it keep the math they rendered with (forward only).
        let activated = try coordinator.activateFormula(E.v2, from: E.morning(25))
        #expect(counter.count == 3)
        #expect(activated.key.schedule.latest == E.v2)
        let ratedEstimate = try #require(rated.evaluation.estimate)
        let activatedEstimate = try #require(activated.evaluation.estimate)
        #expect(ratedEstimate.energyDensityKcalPerKg != 7_000)
        #expect(activatedEstimate.energyDensityKcalPerKg == 7_000)
        #expect(activatedEstimate.meanIntakeKcal == ratedEstimate.meanIntakeKcal)
        #expect(activatedEstimate.trendDeltaKg == ratedEstimate.trendDeltaKg)
        #expect(activatedEstimate.kcalPerDay != ratedEstimate.kcalPerDay)
        #expect(Array(activated.history.days.dropLast()) == Array(rated.history.days.dropLast()))

        // An activation before today would rewrite rendered history: refused,
        // nothing stored, nothing run.
        #expect(throws: EnergySettingsError.activationBeforeToday(today: E.day(25))) {
            try coordinator.activateFormula(.builtinV1, from: E.noon(24))
        }
        #expect(counter.count == 3)
        #expect(try store.energySettings().schedule == activated.key.schedule)

        // Adoption mode is not an engine input.
        try store.setAdoptionMode(.weeklyAutoAdopt)
        _ = try coordinator.refresh()
        #expect(counter.count == 3)
    }

    @Test("an adoption clears the re-adoption suggestion on the next refresh without rerunning the engine")
    func adoptionRefreshesSuggestion() throws {
        let store = try makeFixtureStore()
        try store.registerFormulaVersion(E.v1Row)
        let counter = RecomputeCounter()
        let coordinator = makeCoordinator(store, counter: counter)
        let live = try #require(try coordinator.refresh().calculatedTarget)
        // An open period 300 kcal under the live target: the suggestion shows.
        try store.adoptTarget(
            TargetAdoption(
                calculated: live, adoptedTargetKcal: live.kcalPerDay - 300, macros: E.macros(), formula: .builtinV1
            ),
            on: E.noon(25), calendar: E.calendar, id: uid(1)
        )
        let drifted = try coordinator.refresh()
        #expect(drifted.readoptionSuggestion != nil)
        #expect(coordinator.latest == drifted)

        // Re-adopting at the live value: no input to the engine changed, but
        // the suggestion is gone.
        try store.adoptTarget(
            TargetAdoption(calculated: live, macros: E.macros(), formula: .builtinV1),
            on: E.noon(25), calendar: E.calendar, id: uid(2)
        )
        let adopted = try coordinator.refresh()
        #expect(adopted.readoptionSuggestion == nil)
        #expect(coordinator.latest == adopted)
        #expect(adopted.evaluation == drifted.evaluation)
        #expect(counter.count == 1)
    }

    @Test("a failed computation keeps the last result and is retried by the next refresh")
    func failedComputeIsRetried() throws {
        struct Boom: Error {}
        let store = try makeFixtureStore()
        var shouldFail = false
        var runs = 0
        let coordinator = EnergyRecomputeCoordinator(
            store: store, calendar: E.calendar, today: E.noon(25), historyFrom: E.day(21),
            compute: { key in
                runs += 1
                if shouldFail { throw Boom() }
                return try EnergyBinding.recompute(store: store, key: key, calendar: E.calendar)
            }
        )
        let base = try coordinator.refresh()
        shouldFail = true
        #expect(throws: Boom.self) { try coordinator.setTrendAlpha(0.2) }
        #expect(coordinator.latest == base)
        #expect(try store.energySettings().smoothing.alpha == 0.2)

        shouldFail = false
        let recovered = try coordinator.refresh()
        #expect(runs == 3)
        #expect(recovered.key.weights.smoothing.alpha == 0.2)
    }

    @Test("a new coordinator on a cold-reloaded store reads the persisted α and marks")
    func coldReloadFeedsTheEngine() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let live: LiveEnergy
        do {
            let store = try makeFixtureStore(at: .file(url))
            let coordinator = makeCoordinator(store, counter: RecomputeCounter())
            try coordinator.refresh()
            try coordinator.setTrendAlpha(0.2)
            try coordinator.setRateGoal(kgPerWeek: -0.5)
            live = try coordinator.markDidNotTrack(day: E.day(10))
        }

        let reopened = try SwiftDataStore.phone(at: .file(url))
        let counter = RecomputeCounter()
        let coordinator = makeCoordinator(reopened, counter: counter)
        let fresh = try coordinator.refresh()
        #expect(counter.count == 1)
        #expect(fresh.key.weights.smoothing.alpha == 0.2)
        #expect(fresh.key.rateGoal.kgPerWeek == -0.5)
        #expect(fresh.key.intake.first { $0.day == E.day(10) }?.evidence.markedDidNotTrack == true)
        #expect(fresh == live)
    }
}
