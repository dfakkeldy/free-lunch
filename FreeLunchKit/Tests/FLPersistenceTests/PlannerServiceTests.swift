// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import FLCore
import FLPersistence
import Testing

@Suite @MainActor struct PlannerServiceTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    @Test func shotsMoveSkipAndReproject() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        let profile = MedicationProfileData(known: .semaglutide)
        try store.createMedicationProfile(profile)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let shot = ShotEventData(takenAt: start, dose: try Milligrams(1), medicationID: profile.id)
        try store.createShot(shot)
        let service = PlannerService(store: store, calendar: calendar)
        #expect(try service.reconcile(activeProfile: nil).isEmpty)
        #expect(try service.reconcile(activeProfile: profile).count == 1)
        let plan = try #require(store.plannedShots().first)
        let moved = start.addingTimeInterval(1234)
        _ = try service.moveShot(id: plan.id, to: moved)
        #expect(try service.reconcile(activeProfile: profile).isEmpty)
        let skip = try service.skipShot(id: plan.id, activeProfile: profile)
        #expect(skip.count == 2)
        #expect(try service.reconcile(activeProfile: profile).isEmpty)
        let pending = try #require(store.plannedShots().first { $0.status == .pending })
        let late = ShotEventData(takenAt: start.addingTimeInterval(900_000), dose: try Milligrams(1), medicationID: profile.id)
        let changes = try service.logShot(late, activeProfile: profile)
        #expect(changes.count == 2)
        #expect(try store.plannedShots().first { $0.id == pending.id }?.fulfilledBy == late.id)
        let next = try #require(store.plannedShots().first { $0.status == .pending })
        #expect(next.plannedAt == NextDose.nextDoseAt(shots: [shot, late], activeProfile: profile, calendar: calendar))
        var edited = late
        edited.takenAt = late.takenAt.addingTimeInterval(3600)
        let reschedule = try service.editShot(edited, activeProfile: profile)
        #expect(reschedule.count == 1)
        #expect(reschedule[0].planID == next.id)
        #expect(reschedule[0].oldTime == next.plannedAt)
        #expect(try store.plannedShots().filter { $0.status == .pending }.count == 1)
    }

    @Test func explicitMealAndDiscard() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let service = PlannerService(store: store, calendar: calendar, now: { date })
        let plan = PlannedMealData(plannedAt: date, name: "Lunch", note: "Example")
        try store.createPlannedMeal(plan)
        let unrelated = MealEntryData(createdAt: date, source: .phone)
        try store.createMeal(unrelated)
        _ = try service.logMeal(id: unrelated.id, at: date)
        #expect(try store.plannedMeals()[0].fulfilledBy == nil)
        let draft = try service.startPlannedMeal(id: plan.id)
        #expect(draft.note == "Lunch\nExample")
        #expect(try store.plannedMeals()[0].status == .pending)
        try service.discardDraft(id: draft.id)
        #expect(try store.plannedMeals()[0].fulfilledBy == nil)
        let replacement = try service.startPlannedMeal(id: plan.id)
        _ = try service.logMeal(id: replacement.id, at: date)
        #expect(try store.plannedMeals()[0].status == .done)
        #expect(try store.plannedMeals()[0].fulfilledBy == replacement.id)
    }

    @Test func lapseAtMidnightAcrossDST() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        let service = PlannerService(store: store, calendar: calendar)
        let day = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 12)))
        let midnight = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 10)))
        let plan = PlannedMealData(plannedAt: day, name: "Lunch")
        try store.createPlannedMeal(plan)
        #expect(try service.lapseOverdueMeals(now: midnight.addingTimeInterval(-1)).isEmpty)
        #expect(try service.lapseOverdueMeals(now: midnight).count == 1)
        #expect(try store.plannedMeals()[0].status == .skipped)
    }
}
