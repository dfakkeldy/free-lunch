// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation

/// A notification consumer cancels the old request and schedules the new one,
/// when the corresponding time and identifier are present.
public struct PlannerReminderChange: Sendable, Equatable {
    public let planID: UUID
    public let oldTime: Date?
    public let newTime: Date?
    public let notificationID: String?
}

public enum PlannerError: Error, Equatable {
    case planNotPending(UUID)
    case draftAlreadyLinked(UUID)
}

@MainActor
public final class PlannerService {
    private let store: any PlannerMutationStore & MedicationStore & PlateLifecycleStore
    private let plate: PlateLifecycleService
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(store: any PlannerMutationStore & MedicationStore & PlateLifecycleStore,
                calendar: Calendar, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.plate = PlateLifecycleService(store: store, now: now)
        self.calendar = calendar
        self.now = now
    }

    /// Reconciliation preserves an explicitly moved reminder. A skipped dose
    /// remains skipped until a shot event changes the projection.
    public func reconcile(activeProfile: MedicationProfileData?) throws -> [PlannerReminderChange] {
        let pending = try store.plannedShots().filter { $0.status == .pending }
        let projection = NextDose.nextDoseAt(shots: try store.shots(), activeProfile: activeProfile, calendar: calendar)
        guard let projection else {
            return try pending.map { try remove($0) }
        }
        var changes: [PlannerReminderChange] = []
        for extra in pending.dropFirst() { changes.append(try remove(extra)) }
        if pending.isEmpty {
            let all = try store.plannedShots()
            if all.contains(where: { $0.status == .skipped && $0.plannedAt == projection }) { return changes }
            changes.append(try create(at: projection))
        }
        return changes
    }

    public func moveShot(id: UUID, to date: Date) throws -> PlannerReminderChange {
        var plan = try pendingShot(id)
        let old = plan.plannedAt
        plan.plannedAt = date
        try store.updatePlannedShot(plan)
        return change(plan, old: old, new: date)
    }

    public func skipShot(id: UUID) throws -> PlannerReminderChange {
        var plan = try pendingShot(id)
        plan.status = .skipped
        try store.updatePlannedShot(plan)
        return change(plan, old: plan.plannedAt, new: nil)
    }

    public func logShot(_ shot: ShotEventData, activeProfile: MedicationProfileData?) throws -> [PlannerReminderChange] {
        try store.createShot(shot)
        var changes: [PlannerReminderChange] = []
        if activeProfile?.id == shot.medicationID, activeProfile?.archivedAt == nil,
           var plan = try store.plannedShots().first(where: { $0.status == .pending }) {
            plan.status = .done
            plan.fulfilledBy = shot.id
            try store.updatePlannedShot(plan)
            changes.append(change(plan, old: plan.plannedAt, new: nil))
        }
        return try changes + reproject(activeProfile: activeProfile)
    }

    public func editShot(_ shot: ShotEventData, activeProfile: MedicationProfileData?) throws -> [PlannerReminderChange] {
        try store.updateShot(shot)
        return try reproject(activeProfile: activeProfile)
    }

    public func deleteShot(id: UUID, activeProfile: MedicationProfileData?) throws -> [PlannerReminderChange] {
        try store.deleteShot(id: id)
        return try reproject(activeProfile: activeProfile)
    }

    public func startPlannedMeal(id: UUID) throws -> MealEntryData {
        var plan = try pendingMeal(id)
        guard plan.fulfilledBy == nil else { throw PlannerError.draftAlreadyLinked(id) }
        let draft = try plate.startDraft()
        let note = [plan.name, plan.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        try store.setNote(note.isEmpty ? nil : note, mealID: draft.id)
        plan.fulfilledBy = draft.id
        try store.updatePlannedMeal(plan)
        return try store.meal(id: draft.id)!
    }

    @discardableResult
    public func logMeal(id: UUID, at date: Date? = nil) throws -> MealEntryData {
        let meal = try plate.log(mealID: id, at: date)
        for var plan in try store.plannedMeals() where plan.status == .pending && plan.fulfilledBy == id {
            plan.status = .done
            try store.updatePlannedMeal(plan)
        }
        return meal
    }

    public func discardDraft(id: UUID) throws {
        _ = try plate.resumeDraft(id: id)
        try store.deleteMeal(id: id)
        for var plan in try store.plannedMeals() where plan.status == .pending && plan.fulfilledBy == id {
            plan.fulfilledBy = nil
            try store.updatePlannedMeal(plan)
        }
    }

    public func lapseOverdueMeals(now date: Date? = nil) throws -> [PlannerReminderChange] {
        let today = calendar.startOfDay(for: date ?? now())
        var changes: [PlannerReminderChange] = []
        for var plan in try store.plannedMeals() where plan.status == .pending && plan.plannedAt < today {
            // A draft is not a logged meal; it may still be completed later,
            // but the expired plan no longer claims it.
            plan.status = .skipped
            plan.fulfilledBy = nil
            try store.updatePlannedMeal(plan)
            changes.append(PlannerReminderChange(planID: plan.id, oldTime: plan.plannedAt, newTime: nil, notificationID: plan.notificationID))
        }
        return changes
    }

    private func reproject(activeProfile: MedicationProfileData?) throws -> [PlannerReminderChange] {
        let projection = NextDose.nextDoseAt(shots: try store.shots(), activeProfile: activeProfile, calendar: calendar)
        let pending = try store.plannedShots().filter { $0.status == .pending }
        guard let projection else { return try pending.map { try remove($0) } }
        var changes: [PlannerReminderChange] = []
        if var first = pending.first {
            if first.plannedAt != projection {
                let old = first.plannedAt
                first.plannedAt = projection
                try store.updatePlannedShot(first)
                changes.append(change(first, old: old, new: projection))
            }
            for extra in pending.dropFirst() { changes.append(try remove(extra)) }
        } else { changes.append(try create(at: projection)) }
        return changes
    }

    private func create(at date: Date) throws -> PlannerReminderChange {
        let plan = PlannedShotData(plannedAt: date)
        try store.createPlannedShot(plan)
        return change(plan, old: nil, new: date)
    }
    private func remove(_ plan: PlannedShotData) throws -> PlannerReminderChange {
        try store.deletePlannedShot(id: plan.id)
        return change(plan, old: plan.plannedAt, new: nil)
    }
    private func change(_ plan: PlannedShotData, old: Date?, new: Date?) -> PlannerReminderChange {
        PlannerReminderChange(planID: plan.id, oldTime: old, newTime: new, notificationID: plan.notificationID)
    }
    private func pendingShot(_ id: UUID) throws -> PlannedShotData {
        guard let plan = try store.plannedShots().first(where: { $0.id == id && $0.status == .pending }) else { throw PlannerError.planNotPending(id) }
        return plan
    }
    private func pendingMeal(_ id: UUID) throws -> PlannedMealData {
        guard let plan = try store.plannedMeals().first(where: { $0.id == id && $0.status == .pending }) else { throw PlannerError.planNotPending(id) }
        return plan
    }
}
