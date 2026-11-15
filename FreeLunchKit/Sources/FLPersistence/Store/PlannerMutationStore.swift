// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation

@MainActor
public protocol PlannerMutationStore: PlannerStore {
    func withPlannerTransaction<T>(_ body: () throws -> T) throws -> T
    func updatePlannedShot(_ plan: PlannedShotData) throws
    func deletePlannedShot(id: UUID) throws
    func updatePlannedMeal(_ plan: PlannedMealData) throws
}

extension SwiftDataStore: PlannerMutationStore {
    public func withPlannerTransaction<T>(_ body: () throws -> T) throws -> T {
        if plannerTransactionActive { return try body() }
        plannerTransactionActive = true
        do {
            let result = try body()
            plannerTransactionActive = false
            try commit()
            return result
        } catch {
            plannerTransactionActive = false
            context.rollback()
            throw error
        }
    }

    public func updatePlannedShot(_ plan: PlannedShotData) throws {
        guard let stored = try model(PlannedShot.self, id: plan.id) else { throw FreeLunchStoreError.notFound(plan.id) }
        stored.plannedAt = plan.plannedAt
        stored.notificationID = plan.notificationID
        stored.status = plan.status
        stored.fulfilledBy = plan.fulfilledBy
        stored.doseMg = plan.doseMg
        try commit()
    }

    public func deletePlannedShot(id: UUID) throws {
        guard let stored = try model(PlannedShot.self, id: id) else { throw FreeLunchStoreError.notFound(id) }
        context.delete(stored)
        try commit()
    }

    public func updatePlannedMeal(_ plan: PlannedMealData) throws {
        guard let stored = try model(PlannedMeal.self, id: plan.id) else { throw FreeLunchStoreError.notFound(plan.id) }
        stored.plannedAt = plan.plannedAt
        stored.notificationID = plan.notificationID
        stored.status = plan.status
        stored.fulfilledBy = plan.fulfilledBy
        stored.name = plan.name
        stored.note = plan.note
        try commit()
    }
}
