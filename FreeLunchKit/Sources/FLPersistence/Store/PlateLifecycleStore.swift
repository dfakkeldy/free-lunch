// SPDX-License-Identifier: GPL-3.0-or-later
// Plate lifecycle persistence operations: late logging, item rescaling, and
// AI-record updates. These are deliberately separate from the base store so
// the lifecycle surface can evolve without widening every store lane.
import FLCore
import Foundation

public enum PlateLifecycleError: Error, Equatable, Sendable {
    case mealNotLogged(UUID)
    case invalidQuantity(UUID)
}

@MainActor
public protocol PlateLifecycleStore: MealStore, FoodCatalogStore {
    @discardableResult
    func setLoggedAt(_ loggedAt: Date, mealID: UUID) throws -> MealEntryData

    @discardableResult
    func setItemQuantity(_ quantity: Grams, itemID: UUID) throws -> MealItemData

    func updateAIEstimation(_ record: AIEstimationRecordData) throws
}

@MainActor
extension SwiftDataStore: PlateLifecycleStore {
    @discardableResult
    public func setLoggedAt(_ loggedAt: Date, mealID: UUID) throws -> MealEntryData {
        let meal = try editableMeal(id: mealID)
        guard meal.state == .logged else {
            throw PlateLifecycleError.mealNotLogged(mealID)
        }
        meal.loggedAt = loggedAt
        try commit()
        return meal.asData()
    }

    @discardableResult
    public func setItemQuantity(_ quantity: Grams, itemID: UUID) throws -> MealItemData {
        guard let item = try model(MealItem.self, id: itemID) else {
            throw FreeLunchStoreError.notFound(itemID)
        }
        let newGrams = quantity.value
        guard newGrams > 0, newGrams.isFinite else {
            throw PlateLifecycleError.invalidQuantity(itemID)
        }
        let oldGrams = item.quantityGrams
        guard oldGrams > 0, oldGrams.isFinite else {
            throw PlateLifecycleError.invalidQuantity(itemID)
        }
        guard let meal = item.meal else {
            throw FreeLunchStoreError.notFound(itemID)
        }
        guard meal.source != .healthKitImport else {
            throw FreeLunchStoreError.importedRecordImmutable(meal.id)
        }

        func rescale(_ value: Double) -> Double { value * newGrams / oldGrams }
        item.kcal = rescale(item.kcal)
        item.proteinG = rescale(item.proteinG)
        item.carbsG = rescale(item.carbsG)
        item.fatG = rescale(item.fatG)
        item.fiberG = item.fiberG.map(rescale)
        item.quantityGrams = newGrams
        try commit()
        return item.asData()
    }

    public func updateAIEstimation(_ record: AIEstimationRecordData) throws {
        guard let stored = try model(AIEstimationRecord.self, id: record.id) else {
            throw FreeLunchStoreError.notFound(record.id)
        }
        stored.status = record.status
        stored.responseJSON = record.responseJSON
        stored.userCorrections = record.userCorrections
        stored.hint = record.hint
        try commit()
    }
}
