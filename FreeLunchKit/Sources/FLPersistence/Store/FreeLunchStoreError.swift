// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a `FreeLunchStore` call was refused. Every refusal is decided before
/// the first row is touched, so a refused call leaves the store unchanged.
public enum FreeLunchStoreError: Error, Equatable, Sendable {
    /// No record with this id.
    case notFound(UUID)
    /// A record (or a nested item, component or photo) with this id exists.
    case duplicateID(UUID)
    /// A referenced FoodItem is not stored.
    case missingFood(UUID)
    /// A referenced MedicationProfile is not stored.
    case missingMedication(UUID)
    /// A referenced AIEstimationRecord is not stored.
    case missingAIRecord(UUID)
    /// A referenced PhotoAttachment is not stored.
    case missingPhoto(UUID)
    /// Imported and HealthKit-sourced records never mutate (spec §1); use a
    /// Correction instead.
    case importedRecordImmutable(UUID)
    /// The meal is already logged.
    case mealNotDraft(UUID)
    /// A logged meal needs a `loggedAt`; a draft must not have one.
    case invalidMealState(UUID)
    /// Hunger outside `DomainScale.hunger`.
    case invalidHunger(Int)
    /// Severity outside `DomainScale.sideEffectSeverity`.
    case invalidSeverity(Int)
    /// A MealItem must be either catalog (foodID, no adHocName) or ad-hoc
    /// (adHocName, no foodID).
    case invalidItem(UUID)
    /// A recipe yield must be greater than zero.
    case invalidYield(UUID)
}
