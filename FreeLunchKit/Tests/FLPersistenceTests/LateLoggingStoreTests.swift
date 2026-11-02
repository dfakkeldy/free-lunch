// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 acceptance #8 through the actions the phone calls: logging a
// plate late, and moving a logged plate's `loggedAt`, recompute both days'
// totals; a future `loggedAt` is refused and changes nothing.
//
// The clock is pinned at 2026-01-05 14:00 UTC (`at(hour: 6)`). Plates:
// - Y 400 kcal P 20 C 50 F 12, logged yesterday 10:00.
// - A 200 kcal P 10 C 20 F 5,  logged today 09:00.
// - B 300 kcal P 15 C 30 F 10, logged now (14:00).
// Hand-worked totals before the move: today 500 / 25 / 50 / 15,
// yesterday 400 / 20 / 50 / 12. After B moves to yesterday 12:00:
// today 200 / 10 / 20 / 5, yesterday 700 / 35 / 80 / 22.
import FLCore
import Foundation
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §2 acceptance #8: late logging through the app's actions")
struct LateLoggingStoreTests {
    private let clock = at(hour: 6)
    private let yesterdayMorning = at(day: -1, hour: 2)
    private let todayMorning = at(hour: 1)
    private let yesterdayNoon = at(day: -1, hour: 4)

    private func service(_ store: SwiftDataStore) -> PlateLifecycleService {
        let clock = clock
        return PlateLifecycleService(store: store, now: { clock })
    }

    private func plate(
        _ id: UUID, _ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double,
        in lifecycle: PlateLifecycleService
    ) throws {
        try lifecycle.startDraft(id: id)
        try lifecycle.addAdHocItem(
            name: "Synthetic \(Int(kcal))", quantity: Grams(100),
            nutrition: nutrition(kcal, protein, carbs, fat), toMeal: id
        )
    }

    private func expectTotals(
        _ totals: NutritionTotals, _ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(totals.kcal == kcal, sourceLocation: sourceLocation)
        #expect(totals.proteinG == protein, sourceLocation: sourceLocation)
        #expect(totals.carbsG == carbs, sourceLocation: sourceLocation)
        #expect(totals.fatG == fat, sourceLocation: sourceLocation)
    }

    /// Y yesterday, A and B today, logged through `logPlate`.
    private func seeded() throws -> (SwiftDataStore, PlateLifecycleService) {
        let store = try makeInMemoryStore()
        let lifecycle = service(store)
        try plate(uid(201), 400, 20, 50, 12, in: lifecycle)
        try plate(uid(202), 200, 10, 20, 5, in: lifecycle)
        try plate(uid(203), 300, 15, 30, 10, in: lifecycle)

        let y = try lifecycle.logPlate(mealID: uid(201), at: yesterdayMorning, calendar: utcCalendar)
        #expect(y.meal.state == .logged && y.meal.loggedAt == yesterdayMorning)
        #expect(y.day.day == yesterdayMorning)
        expectTotals(y.day.totals, 400, 20, 50, 12)

        let a = try lifecycle.logPlate(mealID: uid(202), at: todayMorning, calendar: utcCalendar)
        expectTotals(a.day.totals, 200, 10, 20, 5)

        // The unchanged default: no time chosen logs at now.
        let b = try lifecycle.logPlate(mealID: uid(203), at: nil, calendar: utcCalendar)
        #expect(b.meal.loggedAt == clock)
        expectTotals(b.day.totals, 500, 25, 50, 15)
        return (store, lifecycle)
    }

    @Test("logging late lands the plate in the chosen day, with that day's totals")
    func logLate() throws {
        let (_, lifecycle) = try seeded()
        expectTotals(try lifecycle.dayTotals(containing: clock, calendar: utcCalendar), 500, 25, 50, 15)
        expectTotals(try lifecycle.dayTotals(containing: yesterdayNoon, calendar: utcCalendar), 400, 20, 50, 12)
    }

    @Test("moving a logged plate to yesterday moves it and recomputes both days")
    func moveToYesterday() throws {
        let (store, lifecycle) = try seeded()

        let move = try lifecycle.moveLoggedMeal(mealID: uid(203), to: yesterdayNoon, calendar: utcCalendar)
        #expect(move.meal.id == uid(203) && move.meal.state == .logged && move.meal.loggedAt == yesterdayNoon)
        #expect(move.previousDay.day == clock)
        expectTotals(move.previousDay.totals, 200, 10, 20, 5)
        #expect(move.newDay.day == yesterdayNoon)
        expectTotals(move.newDay.totals, 700, 35, 80, 22)

        // Read back independently of the returned values.
        expectTotals(try lifecycle.dayTotals(containing: clock, calendar: utcCalendar), 200, 10, 20, 5)
        expectTotals(try lifecycle.dayTotals(containing: yesterdayNoon, calendar: utcCalendar), 700, 35, 80, 22)
        let yesterday = utcCalendar.dateInterval(of: .day, for: yesterdayNoon)!
        #expect(Set(try store.loggedMeals(in: yesterday).map(\.id)) == [uid(201), uid(203)])
        let today = utcCalendar.dateInterval(of: .day, for: clock)!
        #expect(try store.loggedMeals(in: today).map(\.id) == [uid(202)])
    }

    @Test("moving within the same day keeps that day's totals")
    func moveWithinDay() throws {
        let (_, lifecycle) = try seeded()
        let move = try lifecycle.moveLoggedMeal(mealID: uid(202), to: at(hour: 3), calendar: utcCalendar)
        #expect(move.meal.loggedAt == at(hour: 3))
        expectTotals(move.previousDay.totals, 500, 25, 50, 15)
        expectTotals(move.newDay.totals, 500, 25, 50, 15)
    }

    @Test("a future loggedAt is refused at Log time; the plate stays a draft")
    func futureLogRefused() throws {
        let (store, lifecycle) = try seeded()
        try plate(uid(204), 100, 5, 10, 2, in: lifecycle)

        #expect(throws: LateLoggingError.loggedAtInFuture(uid(204))) {
            try lifecycle.logPlate(mealID: uid(204), at: clock.addingTimeInterval(1), calendar: utcCalendar)
        }
        let draft = try #require(try store.meal(id: uid(204)))
        #expect(draft.state == .draft && draft.loggedAt == nil)
        expectTotals(try lifecycle.dayTotals(containing: clock, calendar: utcCalendar), 500, 25, 50, 15)

        // Exactly now is not the future.
        let logged = try lifecycle.logPlate(mealID: uid(204), at: clock, calendar: utcCalendar)
        #expect(logged.meal.loggedAt == clock)
        expectTotals(logged.day.totals, 600, 30, 60, 17)
    }

    @Test("a future loggedAt is refused on a logged plate; nothing moves")
    func futureMoveRefused() throws {
        let (store, lifecycle) = try seeded()

        #expect(throws: LateLoggingError.loggedAtInFuture(uid(202))) {
            try lifecycle.moveLoggedMeal(mealID: uid(202), to: at(day: 1, hour: 1), calendar: utcCalendar)
        }
        #expect(try store.meal(id: uid(202))?.loggedAt == todayMorning)
        expectTotals(try lifecycle.dayTotals(containing: clock, calendar: utcCalendar), 500, 25, 50, 15)
        expectTotals(try lifecycle.dayTotals(containing: at(day: 1, hour: 1), calendar: utcCalendar), 0, 0, 0, 0)
    }

    @Test("only a logged plate can be moved")
    func moveNeedsLoggedPlate() throws {
        let (_, lifecycle) = try seeded()
        try plate(uid(205), 100, 5, 10, 2, in: lifecycle)
        #expect(throws: PlateLifecycleError.mealNotLogged(uid(205))) {
            try lifecycle.moveLoggedMeal(mealID: uid(205), to: yesterdayNoon, calendar: utcCalendar)
        }
        #expect(throws: FreeLunchStoreError.notFound(uid(299))) {
            try lifecycle.moveLoggedMeal(mealID: uid(299), to: yesterdayNoon, calendar: utcCalendar)
        }
    }
}
