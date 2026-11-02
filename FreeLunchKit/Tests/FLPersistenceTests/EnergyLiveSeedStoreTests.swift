// SPDX-License-Identifier: GPL-3.0-or-later
// Pause honesty through the store whatever range is rendered (fl-m3-06):
// spec §3 acceptance #3 at the binding level, and the recompute key's
// intake covering the live series' seed range.
//
// Fixture: EnergyStoreFixture (2000 kcal plates on days 0...40, trend
// 80 − 0.0625·k kg on days −22...40) with days 20–27 marked "didn't track".
// Hand-counted complete days per window: day 27 → 14 (tracking, 2481.25
// under v1), day 28 onward → 13 (paused, insufficient intake). Values were
// computed by hand and with a throwaway script outside the repo.
import FLCore
import FLEnergyCore
import Foundation
import Testing
@testable import FLPersistence

private typealias E = EnergyStoreFixture

private let marks = Set((20...27).map(E.noon))

@MainActor
private func key(
    _ store: SwiftDataStore,
    today: Int,
    historyFrom: Int,
    schedule: FormulaActivationSchedule = FormulaActivationSchedule()
) throws -> EnergyRecomputeKey {
    try EnergyBinding.key(
        store: store, today: E.noon(today), historyFrom: E.day(historyFrom), weights: E.weights,
        schedule: schedule, rateGoal: E.rate(-0.5), calendar: E.calendar, markedDidNotTrack: marks
    )
}

@MainActor
@Suite("Energy binding: pause honesty independent of the rendered range")
struct EnergyLiveSeedStoreTests {
    @Test("paused today with historyFrom == today shows the last valid estimate and its as-of date; nothing new is emitted")
    func pausedTodayRenderedAlone() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store)
        try store.registerFormulaVersion(E.v1Row)

        let live = try EnergyBinding.recompute(store: store, key: key(store, today: 28, historyFrom: 28), calendar: E.calendar)
        #expect(live.history.days.count == 1)
        let today = try #require(live.today)
        #expect(today.day == E.day(28))
        #expect(today.state == .pausedInsufficientIntake)
        #expect(today.displayedKcalPerDay == 2_481.25)
        #expect(today.displayedAsOf == E.day(27))
        #expect(today.displayedFormulaName == "FL-EB v1")

        // No new estimate value: today's evaluation is paused, carries no
        // value, and no calculated target is made from the old estimate.
        #expect(live.evaluation == .paused(.insufficientIntake))
        #expect(live.evaluation.estimate == nil)
        #expect(live.calculatedTarget == nil)
        #expect(live.readoptionSuggestion == nil)

        // The same day rendered as part of a longer range is identical.
        let wide = try EnergyBinding.recompute(store: store, key: key(store, today: 28, historyFrom: 21), calendar: E.calendar)
        #expect(wide.today == today)
        #expect(Array(wide.history.days.suffix(1)) == live.history.days)
    }

    @Test("a paused today under a newer version carries the estimate with the version it was made under")
    func pausedTodayKeepsRecordedVersion() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store)
        let schedule = try FormulaActivationSchedule().activating(E.v2, from: E.day(28), calendar: E.calendar)

        let live = try EnergyBinding.recompute(
            store: store, key: key(store, today: 30, historyFrom: 30, schedule: schedule), calendar: E.calendar
        )
        let today = try #require(live.today)
        #expect(today.formulaName == "FL-EB v2 (synthetic)")
        #expect(today.displayedKcalPerDay == 2_481.25) // v1's value, not v2's 2437.5
        #expect(today.displayedAsOf == E.day(27))
        #expect(today.displayedFormulaName == "FL-EB v1")
        #expect(live.calculatedTarget == nil)
    }

    @Test("the key's intake covers every stored day through today, whatever historyFrom is")
    func keyIntakeCoversSeedRange() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store)

        let late = try key(store, today: 28, historyFrom: 28)
        #expect(late.day == E.day(28))
        #expect(late.historyFrom == E.day(28))
        // Days 0 (the first stored meal) through 28, not 7 (= 28 − 21).
        #expect(late.intake.map(\.day) == (0...28).map(E.day))
        #expect(late.intake.allSatisfy { $0.intakeKcal == 2_000 })
        #expect(late.intake.filter(\.evidence.markedDidNotTrack).map(\.day) == (20...27).map(E.day))

        // Another rendered range reads the same intake; only the range
        // trigger fires.
        let early = try key(store, today: 28, historyFrom: 21)
        #expect(early.intake == late.intake)
        #expect(EnergyRecomputeReason.reasons(from: early, to: late) == [.historyRangeChanged])
        #expect(EnergyRecomputeReason.reasons(from: late, to: try key(store, today: 28, historyFrom: 28)).isEmpty)
    }

    @Test("an edit to a day older than the rendered window changes the key and the carried estimate")
    func oldEditIsATrigger() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store)
        let before = try key(store, today: 28, historyFrom: 28)

        // Day 6 is before 28 − 21 = 7, so a key bounded by the rendered
        // window would not see it, but it is inside day 27's window (6–26),
        // which made the carried estimate.
        try store.addItem(
            .adHoc(id: uid(7_101), name: "Backfill", quantity: Grams(10), nutrition: E.kcal(210)),
            toMeal: E.mealID(6)
        )
        let after = try key(store, today: 28, historyFrom: 28)
        #expect(EnergyRecomputeReason.reasons(from: before, to: after) == [.intakeChanged])

        // Day 27's 14 complete days now sum 14 × 2000 + 210, a mean of
        // 2015 kcal; 2015 + 1.3125 × 7700 / 21 = 2496.25 kcal/day.
        let live = try EnergyBinding.recompute(store: store, key: after, calendar: E.calendar)
        let today = try #require(live.today)
        #expect(today.state == .pausedInsufficientIntake)
        #expect(today.displayedKcalPerDay == 2_496.25)
        #expect(today.displayedAsOf == E.day(27))
    }

    @Test("all stored intake through a day: meals and marks with no lower bound, nothing after the day")
    func allStoredIntake() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store, days: 0...5)
        let intake = try store.dayIntakes(
            through: E.noon(3), calendar: E.calendar,
            markedDidNotTrack: [E.noon(-400), E.noon(2), E.noon(4)]
        )
        #expect(intake.map(\.day) == [E.day(-400), E.day(0), E.day(1), E.day(2), E.day(3)])
        #expect(intake[0] == DayIntake(day: E.day(-400), intakeKcal: 0, evidence: DayIntakeEvidence(markedDidNotTrack: true)))
        #expect(intake[3] == DayIntake(
            day: E.day(2), intakeKcal: 2_000,
            evidence: DayIntakeEvidence(loggedMealCount: 1, markedDidNotTrack: true)
        ))
        #expect(try store.dayIntakes(through: E.noon(3), calendar: E.calendar)
            == store.dayIntakes(from: E.day(-1_000), through: E.day(3), calendar: E.calendar))
    }
}
