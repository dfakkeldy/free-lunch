// SPDX-License-Identifier: GPL-3.0-or-later
// The engine's inputs read from stored meals, the recompute triggers, and
// pause honesty through the binding (spec §3 "Day completeness",
// "Recompute", "Paused behavior").
import FLCore
import FLEnergyCore
import Foundation
import Testing
@testable import FLPersistence

private typealias E = EnergyStoreFixture

@MainActor
@Suite("Energy binding: intake read from stored meals")
struct StoredDayIntakeTests {
    @Test("logged plates sum per calendar day; imports are reconstructed days; drafts never count; marks are carried")
    func dayIntakes() throws {
        let store = try makeInMemoryStore()
        func plate(_ id: Int, day: Int, hour: Double, kcal: [Double], source: MealSource = .phone, logged: Bool = true) throws {
            let at = E.day(day).addingTimeInterval(hour * 3_600)
            try store.createMeal(MealEntryData(
                id: uid(id),
                state: logged ? .logged : .draft,
                createdAt: at,
                loggedAt: logged ? at : nil,
                items: kcal.enumerated().map { index, value in
                    MealItemData(
                        id: uid(id * 10 + index), order: index, foodID: nil, adHocName: "Part",
                        quantity: Grams(100), nutrition: E.kcal(value), provenance: .typed
                    )
                },
                source: source
            ))
        }
        try plate(1, day: 1, hour: 0, kcal: [300, 200])            // midnight belongs to day 1
        try plate(2, day: 1, hour: 23.5, kcal: [1_000])
        try plate(3, day: 2, hour: 12, kcal: [1_800], source: .healthKitImport)
        try plate(4, day: 3, hour: 12, kcal: [700], source: .watchQuickLog)
        try plate(5, day: 3, hour: 13, kcal: [999], logged: false)  // draft
        try plate(6, day: 4, hour: 12, kcal: [400], source: .phone)
        try plate(7, day: 9, hour: 12, kcal: [5_000])               // outside the range

        let intakes = try store.dayIntakes(
            from: E.noon(1), through: E.noon(5), calendar: E.calendar,
            markedDidNotTrack: [E.noon(4), E.morning(5), E.noon(8)]
        )
        #expect(intakes == [
            DayIntake(day: E.day(1), intakeKcal: 1_500, evidence: DayIntakeEvidence(loggedMealCount: 2)),
            DayIntake(day: E.day(2), intakeKcal: 1_800, evidence: DayIntakeEvidence(hasReconstructedDietaryEnergy: true)),
            DayIntake(day: E.day(3), intakeKcal: 700, evidence: DayIntakeEvidence(loggedMealCount: 1)),
            DayIntake(
                day: E.day(4), intakeKcal: 400,
                evidence: DayIntakeEvidence(loggedMealCount: 1, markedDidNotTrack: true)
            ),
            DayIntake(day: E.day(5), intakeKcal: 0, evidence: DayIntakeEvidence(markedDidNotTrack: true))
        ])
        #expect(try store.dayIntakes(from: E.day(5), through: E.day(1), calendar: E.calendar).isEmpty)
    }

    @Test("a day with a native meal and an import uses native intake only; removing the native meal flips it to the reconstruction")
    func doubleCountBoundary() throws {
        let store = try makeInMemoryStore()
        func plate(_ id: Int, hour: Double, kcal: Double, source: MealSource) throws {
            let at = E.day(6).addingTimeInterval(hour * 3_600)
            try store.createMeal(MealEntryData(
                id: uid(id), state: .logged, createdAt: at, loggedAt: at,
                items: [MealItemData(
                    id: uid(id * 10), order: 0, foodID: nil, adHocName: "Part",
                    quantity: Grams(100), nutrition: E.kcal(kcal), provenance: .typed
                )],
                source: source
            ))
        }
        try plate(1, hour: 8, kcal: 2_200, source: .healthKitImport)
        try plate(2, hour: 9, kcal: 600, source: .phone)
        try plate(3, hour: 19, kcal: 900, source: .watchQuickLog)

        // Native 600 + 900 = 1500; the imported 2200 is ignored, never added.
        #expect(try store.dayIntakes(from: E.day(6), through: E.day(6), calendar: E.calendar) == [
            DayIntake(day: E.day(6), intakeKcal: 1_500, evidence: DayIntakeEvidence(loggedMealCount: 2))
        ])

        try store.deleteMeal(id: uid(2))
        try store.deleteMeal(id: uid(3))
        #expect(try store.dayIntakes(from: E.day(6), through: E.day(6), calendar: E.calendar) == [
            DayIntake(day: E.day(6), intakeKcal: 2_200, evidence: DayIntakeEvidence(hasReconstructedDietaryEnergy: true))
        ])
    }
}

@MainActor
@Suite("Energy binding: recompute triggers")
struct EnergyRecomputeTriggerTests {
    private func key(
        _ store: SwiftDataStore,
        today: Int,
        weights: TrendSeries = E.weights,
        schedule: FormulaActivationSchedule = FormulaActivationSchedule(),
        rate: Double = -0.5,
        marks: Set<Date> = []
    ) throws -> EnergyRecomputeKey {
        try EnergyBinding.key(
            store: store, today: E.noon(today), historyFrom: E.day(21), weights: weights,
            schedule: schedule, rateGoal: E.rate(rate), calendar: E.calendar, markedDidNotTrack: marks
        )
    }

    @Test("each spec §3 trigger is reported; unchanged inputs need no recompute")
    func reasons() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store)
        let base = try key(store, today: 25)

        #expect(EnergyRecomputeReason.reasons(from: nil, to: base) == [.firstRun])
        #expect(EnergyRecomputeReason.reasons(from: base, to: try key(store, today: 25)).isEmpty)
        // A later instant on the same day is the same day.
        let sameDay = try EnergyBinding.key(
            store: store, today: E.day(25).addingTimeInterval(23 * 3_600), historyFrom: E.day(21),
            weights: E.weights, schedule: FormulaActivationSchedule(), rateGoal: E.rate(-0.5), calendar: E.calendar
        )
        #expect(EnergyRecomputeReason.reasons(from: base, to: sameDay).isEmpty)

        // First foreground of a new day: the window moves, so the intake
        // read moves too.
        #expect(EnergyRecomputeReason.reasons(from: base, to: try key(store, today: 26)).contains(.newDay))

        // Backfill edit.
        try store.addItem(
            .adHoc(id: uid(7_001), name: "Backfill", quantity: Grams(10), nutrition: E.kcal(50)),
            toMeal: E.mealID(12)
        )
        let edited = try key(store, today: 25)
        #expect(EnergyRecomputeReason.reasons(from: base, to: edited) == [.intakeChanged])

        // "Didn't track" mark.
        #expect(EnergyRecomputeReason.reasons(from: edited, to: try key(store, today: 25, marks: [E.day(7)])) == [.intakeChanged])

        // Weight correction.
        let corrected = TrendSeries(smoothing: .standard, points: Array(E.weights.points.dropLast()))
        #expect(EnergyRecomputeReason.reasons(from: edited, to: try key(store, today: 25, weights: corrected)) == [.weightChanged])

        // α change.
        let smoother = TrendSeries(smoothing: try #require(TrendSmoothing(alpha: 0.2)), points: E.weights.points)
        #expect(EnergyRecomputeReason.reasons(from: edited, to: try key(store, today: 25, weights: smoother)) == [.smoothingChanged])

        // Formula activation and a new rate goal.
        let activated = try FormulaActivationSchedule().activating(E.v2, from: E.day(26), calendar: E.calendar)
        #expect(EnergyRecomputeReason.reasons(from: edited, to: try key(store, today: 25, schedule: activated)) == [.formulaActivated])
        #expect(EnergyRecomputeReason.reasons(from: edited, to: try key(store, today: 25, rate: -0.25)) == [.rateGoalChanged])
    }

    @Test("the key reads intake from the window before the first rendered day through today")
    func keyWindow() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store)
        let key = try key(store, today: 25)
        #expect(key.day == E.day(25))
        #expect(key.historyFrom == E.day(21))
        // Days 0 (= 21 − 21) through 25.
        #expect(key.intake.map(\.day) == (0...25).map(E.day))
        #expect(key.intake.allSatisfy { $0.intakeKcal == 2_000 && $0.evidence == DayIntakeEvidence(loggedMealCount: 1) })
    }
}

@MainActor
@Suite("Energy binding: pause honesty through the store")
struct StoredPauseHonestyTests {
    @Test("a paused day keeps the last valid estimate with its as-of date and yields no calculated target")
    func pausedKeepsLastValid() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store)
        try store.registerFormulaVersion(E.v1Row)
        try store.adoptTarget(
            TargetAdoption(
                calculated: CalculatedTarget(expenditureKcal: 2_481.25, rateGoal: E.rate(-0.5)),
                adoptedTargetKcal: 1_500, macros: E.macros(), formula: .builtinV1
            ),
            on: E.noon(22), calendar: E.calendar, id: uid(1)
        )
        let ledgerBefore = try E.bytes(store.targetLedger())

        // Days 20–27 marked "didn't track". Complete days in each window
        // (hand-counted): day 25 → 16, 26 → 15, 27 → 14 (tracking), 28 → 13
        // (paused, insufficient intake).
        let marks = Set((20...27).map(E.noon))
        let live = try EnergyBinding.recompute(
            store: store, today: E.noon(28), historyFrom: E.day(25), weights: E.weights,
            schedule: FormulaActivationSchedule(), rateGoal: E.rate(-0.5), calendar: E.calendar,
            markedDidNotTrack: marks
        )
        #expect(live.history.days.map(\.state) == [.tracking, .tracking, .tracking, .pausedInsufficientIntake])
        #expect(live.evaluation.state == .paused(.insufficientIntake))
        let today = try #require(live.today)
        #expect(today.day == E.day(28))
        #expect(today.displayedKcalPerDay == 2_481.25)
        #expect(today.displayedAsOf == E.day(27))
        #expect(live.calculatedTarget == nil)
        #expect(live.readoptionSuggestion == nil)
        #expect(try E.bytes(store.targetLedger()) == ledgerBefore)
    }
}
