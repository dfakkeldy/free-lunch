// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation

/// A nil old time denotes a schedule, a nil new time denotes a cancellation,
/// and two times denote a reschedule of the same notification identifier.
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

    public init(
        store: any PlannerMutationStore & MedicationStore & PlateLifecycleStore,
        calendar: Calendar, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.plate = PlateLifecycleService(store: store, now: now)
        self.calendar = calendar
        self.now = now
    }

    /// Reconciliation preserves an explicitly moved reminder. A skipped dose
    /// replacement remains at its projected time until a shot event.
    public func reconcile(activeProfile: MedicationProfileData?) throws -> [PlannerReminderChange] {
        try store.withPlannerTransaction {
            let pending = try store.plannedShots().filter { $0.status == .pending }
            let projection = NextDose.nextDoseAt(
                shots: try store.shots(), activeProfile: activeProfile, calendar: calendar)
            guard let projection else {
                return try pending.map { try remove($0) }
            }
            var changes: [PlannerReminderChange] = []
            for extra in pending.dropFirst() { changes.append(try remove(extra)) }
            if pending.isEmpty {
                changes.append(try create(at: projection))
            }
            return changes
        }
    }

    public func moveShot(id: UUID, to date: Date) throws -> PlannerReminderChange {
        try store.withPlannerTransaction {
            var plan = try pendingShot(id)
            let old = plan.plannedAt
            plan.plannedAt = date
            try store.updatePlannedShot(plan)
            return change(plan, old: old, new: date)
        }
    }

    public func skipShot(id: UUID, activeProfile: MedicationProfileData?) throws
        -> [PlannerReminderChange]
    {
        try store.withPlannerTransaction {
            var plan = try pendingShot(id)
            let projection = NextDose.nextDoseAt(
                shots: try store.shots(), activeProfile: activeProfile, calendar: calendar)
            plan.status = .skipped
            try store.updatePlannedShot(plan)
            var changes = [change(plan, old: plan.plannedAt, new: nil)]
            if let projection, let profile = activeProfile,
                let next = calendar.date(
                    byAdding: .day, value: profile.intervalDays, to: max(projection, plan.plannedAt))
            {
                changes.append(try create(at: next))
            }
            return changes
        }
    }

    public func logShot(_ shot: ShotEventData, activeProfile: MedicationProfileData?) throws
        -> [PlannerReminderChange]
    {
        try store.withPlannerTransaction {
            let before = try projection(activeProfile)
            try store.createShot(shot)
            let after = try projection(activeProfile)
            var changes: [PlannerReminderChange] = []
            if before != after, activeProfile?.id == shot.medicationID, activeProfile?.archivedAt == nil,
                var plan = try store.plannedShots().first(where: { $0.status == .pending })
            {
                plan.status = .done
                plan.fulfilledBy = shot.id
                try store.updatePlannedShot(plan)
                changes.append(change(plan, old: plan.plannedAt, new: nil))
            }
            if !changes.isEmpty || before != after {
                changes += try reproject(activeProfile: activeProfile)
            }
            return changes
        }
    }

    public func editShot(_ shot: ShotEventData, activeProfile: MedicationProfileData?) throws
        -> [PlannerReminderChange]
    {
        try store.withPlannerTransaction {
            let before = try projection(activeProfile)
            let original = try store.shot(id: shot.id)
            try store.updateShot(shot)
            if original?.medicationID != shot.medicationID { try clearShotLinks(id: shot.id) }
            return try before == projection(activeProfile) ? [] : reproject(activeProfile: activeProfile)
        }
    }

    public func deleteShot(id: UUID, activeProfile: MedicationProfileData?) throws
        -> [PlannerReminderChange]
    {
        try store.withPlannerTransaction {
            let before = try projection(activeProfile)
            try store.deleteShot(id: id)
            try clearShotLinks(id: id)
            return try before == projection(activeProfile) ? [] : reproject(activeProfile: activeProfile)
        }
    }

    public func startPlannedMeal(id: UUID) throws -> MealEntryData {
        try store.withPlannerTransaction {
            var plan = try pendingMeal(id)
            if let linked = plan.fulfilledBy {
                if let existing = try store.meal(id: linked) {
                    if existing.state == .draft { return existing }
                    plan.status = .done
                    try store.updatePlannedMeal(plan)
                    return existing
                }
                plan.fulfilledBy = nil
            }
            let draft = try plate.startDraft()
            let note = [plan.name, plan.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(
                separator: "\n")
            try store.setNote(note.isEmpty ? nil : note, mealID: draft.id)
            plan.fulfilledBy = draft.id
            try store.updatePlannedMeal(plan)
            guard let result = try store.meal(id: draft.id) else {
                throw FreeLunchStoreError.notFound(draft.id)
            }
            return result
        }
    }

    @discardableResult
    public func logMeal(id: UUID, at date: Date? = nil) throws -> MealEntryData {
        try store.withPlannerTransaction {
            let meal = try plate.log(mealID: id, at: date)
            for var plan in try store.plannedMeals()
            where plan.status == .pending && plan.fulfilledBy == id {
                plan.status = .done
                try store.updatePlannedMeal(plan)
            }
            return meal
        }
    }

    public func discardDraft(id: UUID) throws {
        try store.withPlannerTransaction {
            _ = try plate.resumeDraft(id: id)
            try store.deleteMeal(id: id)
            for var plan in try store.plannedMeals()
            where plan.status == .pending && plan.fulfilledBy == id {
                plan.fulfilledBy = nil
                try store.updatePlannedMeal(plan)
            }
        }
    }

    public func lapseOverdueMeals(now date: Date? = nil) throws -> [PlannerReminderChange] {
        try store.withPlannerTransaction {
            let today = calendar.startOfDay(for: date ?? now())
            var changes: [PlannerReminderChange] = []
            for var plan in try store.plannedMeals() where plan.status == .pending {
                let linkedMeal = try plan.fulfilledBy.flatMap { try store.meal(id: $0) }
                if linkedMeal?.state == .logged {
                    plan.status = .done
                } else if plan.plannedAt < today {
                    plan.status = .skipped
                    plan.fulfilledBy = nil
                } else {
                    continue
                }
                try store.updatePlannedMeal(plan)
                changes.append(
                    PlannerReminderChange(
                        planID: plan.id, oldTime: plan.plannedAt, newTime: nil,
                        notificationID: plan.notificationID))
            }
            return changes
        }
    }

    /// Call after changing the active profile or its interval.
    public func profileChanged(activeProfile: MedicationProfileData?) throws -> [PlannerReminderChange] {
        try store.withPlannerTransaction { try reproject(activeProfile: activeProfile) }
    }

    private func clearShotLinks(id: UUID) throws {
        for var plan in try store.plannedShots() where plan.status == .done && plan.fulfilledBy == id {
            plan.status = .skipped
            plan.fulfilledBy = nil
            try store.updatePlannedShot(plan)
        }
    }

    private func projection(_ profile: MedicationProfileData?) throws -> Date? {
        NextDose.nextDoseAt(shots: try store.shots(), activeProfile: profile, calendar: calendar)
    }

    private func reproject(activeProfile: MedicationProfileData?) throws -> [PlannerReminderChange] {
        let projection = NextDose.nextDoseAt(
            shots: try store.shots(), activeProfile: activeProfile, calendar: calendar)
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
        } else {
            changes.append(try create(at: projection))
        }
        return changes
    }

    private func create(at date: Date) throws -> PlannerReminderChange {
        let id = UUID()
        let plan = PlannedShotData(id: id, plannedAt: date, notificationID: id.uuidString)
        try store.createPlannedShot(plan)
        return change(plan, old: nil, new: date)
    }
    private func remove(_ plan: PlannedShotData) throws -> PlannerReminderChange {
        try store.deletePlannedShot(id: plan.id)
        return change(plan, old: plan.plannedAt, new: nil)
    }
    private func change(_ plan: PlannedShotData, old: Date?, new: Date?) -> PlannerReminderChange {
        PlannerReminderChange(
            planID: plan.id, oldTime: old, newTime: new, notificationID: plan.notificationID)
    }
    private func pendingShot(_ id: UUID) throws -> PlannedShotData {
        guard let plan = try store.plannedShots().first(where: { $0.id == id && $0.status == .pending })
        else { throw PlannerError.planNotPending(id) }
        return plan
    }
    private func pendingMeal(_ id: UUID) throws -> PlannedMealData {
        guard let plan = try store.plannedMeals().first(where: { $0.id == id && $0.status == .pending })
        else { throw PlannerError.planNotPending(id) }
        return plan
    }
}
