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
        let shot = ShotEventData(takenAt: start, dose: Milligrams(1), medicationID: profile.id)
        try store.createShot(shot)
        let service = PlannerService(store: store, calendar: calendar)
        #expect(try service.reconcile(activeProfile: nil).isEmpty)
        #expect(try service.reconcile(activeProfile: profile).count == 1)
        let plan = try #require(store.plannedShots().first)
        #expect(plan.notificationID == plan.id.uuidString)
        let moved = start.addingTimeInterval(1234)
        _ = try service.moveShot(id: plan.id, to: moved)
        #expect(try service.reconcile(activeProfile: profile).isEmpty)
        let skip = try service.skipShot(id: plan.id, activeProfile: profile)
        #expect(skip.count == 2)
        #expect(try service.reconcile(activeProfile: profile).isEmpty)
        let pending = try #require(store.plannedShots().first { $0.status == .pending })
        let late = ShotEventData(takenAt: start.addingTimeInterval(900_000), dose: Milligrams(1), medicationID: profile.id)
        let changes = try service.logShot(late, activeProfile: profile)
        #expect(changes.count == 2)
        #expect(changes[0].notificationID == pending.notificationID)
        #expect(changes[0].newTime == nil)
        #expect(changes[1].newTime == NextDose.nextDoseAt(shots: [shot, late], activeProfile: profile, calendar: calendar))
        #expect(changes[1].notificationID != nil)
        #expect(try store.plannedShots().first { $0.id == pending.id }?.fulfilledBy == late.id)
        let next = try #require(store.plannedShots().first { $0.status == .pending })
        #expect(next.plannedAt == NextDose.nextDoseAt(shots: [shot, late], activeProfile: profile, calendar: calendar))
        let backfill = ShotEventData(takenAt: start.addingTimeInterval(-3600), dose: Milligrams(1), medicationID: profile.id)
        #expect(try service.logShot(backfill, activeProfile: profile).isEmpty)
        #expect(try store.plannedShots().first { $0.status == .pending }?.id == next.id)
        var edited = late
        edited.takenAt = late.takenAt.addingTimeInterval(3600)
        let reschedule = try service.editShot(edited, activeProfile: profile)
        #expect(reschedule.count == 1)
        #expect(reschedule[0].planID == next.id)
        #expect(reschedule[0].oldTime == next.plannedAt)
        #expect(reschedule[0].notificationID == next.notificationID)
        #expect(try store.plannedShots().filter { $0.status == .pending }.count == 1)
        _ = try service.deleteShot(id: late.id, activeProfile: profile)
        let formerlyDone = try #require(store.plannedShots().first { $0.id == pending.id })
        #expect(formerlyDone.status == .skipped)
        #expect(formerlyDone.fulfilledBy == nil)
    }

    @Test func explicitMealAndDiscard() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let service = PlannerService(store: store, calendar: calendar, now: { date })
        let plan = PlannedMealData(plannedAt: date, name: "Lunch", note: "Example")
        try store.createPlannedMeal(plan)
        let unrelated = MealEntryData(createdAt: date, source: .phone)
        try store.createMeal(unrelated)
        _ = try PlateLifecycleService(store: store).log(mealID: unrelated.id, at: date)
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
    @Test func unrelatedEditsAndRepeatedSkipsPreserveIntent() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        let profile = MedicationProfileData(known: .semaglutide)
        try store.createMedicationProfile(profile)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var shot = ShotEventData(takenAt: date, dose: Milligrams(1), medicationID: profile.id)
        try store.createShot(shot)
        let service = PlannerService(store: store, calendar: calendar)
        _ = try service.reconcile(activeProfile: profile)
        let original = try #require(store.plannedShots().first)
        _ = try service.skipShot(id: original.id, activeProfile: profile)
        let first = try #require(store.plannedShots().first { $0.status == .pending })
        shot.note = "Updated"
        #expect(try service.editShot(shot, activeProfile: profile).isEmpty)
        #expect(try store.plannedShots().first { $0.id == first.id }?.plannedAt == first.plannedAt)
        _ = try service.skipShot(id: first.id, activeProfile: profile)
        let second = try #require(store.plannedShots().first { $0.status == .pending })
        #expect(second.plannedAt == calendar.date(byAdding: .day, value: profile.intervalDays, to: first.plannedAt))
        let removed = try service.deleteShot(id: shot.id, activeProfile: profile)
        #expect(removed.count == 1)
        #expect(try store.plannedShots().allSatisfy { $0.status != .pending })
    }

    @Test func transactionRollsBackAndLapseRecognizesLoggedDraft() throws {
        enum Failure: Error { case injected }
        let store = try SwiftDataStore.phone(at: .inMemory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = PlannedMealData(plannedAt: date, name: "Meal")
        #expect(throws: Failure.self) {
            try store.withPlannerTransaction {
                try store.createPlannedMeal(plan)
                throw Failure.injected
            }
        }
        #expect(try store.plannedMeals().isEmpty)
        try store.createPlannedMeal(plan)
        let service = PlannerService(store: store, calendar: calendar, now: { date })
        let draft = try service.startPlannedMeal(id: plan.id)
        #expect(try service.startPlannedMeal(id: plan.id).id == draft.id)
        try store.deleteMeal(id: draft.id)
        let replacement = try service.startPlannedMeal(id: plan.id)
        _ = try PlateLifecycleService(store: store).log(mealID: replacement.id, at: date)
        _ = try service.lapseOverdueMeals(now: date.addingTimeInterval(172_800))
        #expect(try store.plannedMeals()[0].status == .done)
        #expect(try store.plannedMeals()[0].fulfilledBy == replacement.id)
    }

}
