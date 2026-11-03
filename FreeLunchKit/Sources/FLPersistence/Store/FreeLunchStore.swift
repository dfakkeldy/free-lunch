// SPDX-License-Identifier: GPL-3.0-or-later
// FreeLunchStore — the protocol boundary in front of persistence (the GRDB
// escape hatch). Every signature speaks FLCore value types; no `@Model`
// class and no `ModelContainer` appears, so SwiftData stays swappable:
// replacing it means writing another conformer, and nothing else changes.
// `SwiftDataStore` is the one conformer today.
//
// The store is split into lane protocols so later work adds a lane in its
// own file (weight mirror and corrections, watch working set, targets) and
// only appends that lane to `FreeLunchStore`'s list.
//
// ## Integrity rules carried by the API's shape (spec §1)
//
// - **No method deletes a FoodItem or a MedicationProfile.** Foods archive
//   once referenced; the absent method is the guarantee, because SwiftData
//   does not enforce `.deny` delete rules.
// - **Snapshots are the record.** A catalog item's nutrition is computed
//   from the food when the item is added, then never rewritten from the
//   food again; `updateFood` touches the catalog row only.
// - **Imported records never mutate.** Meals with source `.healthKitImport`
//   and shots with source `.shotsyImport` refuse edits and deletes with
//   `importedRecordImmutable`.
// - **Deleting a MealEntry** cascades its items and photos, and removes the
//   AI estimation records that only that meal used. Foods and other meals
//   are untouched. (Deleting the meal's HealthKit dietary-energy write is a
//   later section's work.)
//
// ## Threading
//
// `@MainActor`, compiler-enforced: one isolation domain per store. Hand
// data across actors as the value types this API returns, never the store.
import FLCore
import Foundation

/// The whole store: every lane.
@MainActor
public protocol FreeLunchStore: FoodCatalogStore, MealStore, MedicationStore, PlannerStore, JournalStore {}

/// Foods and recipes (spec §1 FoodItem, Recipe).
@MainActor
public protocol FoodCatalogStore: AnyObject {
    /// Throws `duplicateID` if `food.id` exists. Typeahead fields and
    /// `archivedAt` are stored as given (seeding and import).
    func createFood(_ food: FoodItemData) throws
    func food(id: UUID) throws -> FoodItemData?
    /// Sorted by name, then id. `includingArchived: false` hides archived
    /// foods from typeahead; they stay resolvable through `food(id:)`.
    func foods(includingArchived: Bool) throws -> [FoodItemData]
    /// Overwrites name, brand, per-100 g nutrition, isLiquid, servings and
    /// origin. Leaves the typeahead fields (store-maintained) and
    /// `archivedAt` (`archiveFood`'s alone) untouched. Never touches any
    /// MealItem snapshot.
    func updateFood(_ food: FoodItemData) throws
    func archiveFood(id: UUID, at date: Date) throws

    /// Inserts every food in one save: all or nothing. Throws `duplicateID`
    /// if an id exists already or repeats within `foods`, before inserting
    /// anything. Stored as given, like `createFood` (catalog seeding).
    func createFoods(_ foods: [FoodItemData]) throws

    /// Saves a user's edit of a catalog food (spec §11: editing a seeded
    /// food forks it). `edited` carries the food's `id` and the new name,
    /// brand, per-100 g nutrition, isLiquid and servings.
    ///
    /// - A `.seeded` food is never changed. If the edit differs from the
    ///   stored values, a new `.custom` food with id `forkID` is created
    ///   from the edit, carrying over the original's typeahead fields so it
    ///   keeps its rank, and the original is archived at `date`, all in one
    ///   save. An edit that changes nothing creates no fork. A seed reload
    ///   never brings the archived original back, because it keeps its id.
    /// - Any other food is updated in place, as `updateFood` does.
    ///
    /// Returns the food the edit left in effect: the fork, or the updated or
    /// unchanged food. Throws `notFound`, or `duplicateID` if a fork is
    /// needed and `forkID` exists.
    @discardableResult
    func editFood(_ edited: FoodItemData, forkID: UUID, at date: Date) throws -> FoodItemData

    /// Throws `duplicateID` for the recipe or a component id,
    /// `missingFood` for a component's food, `invalidYield` for a yield of
    /// zero.
    func createRecipe(_ recipe: RecipeData) throws
    func recipe(id: UUID) throws -> RecipeData?
    /// Sorted by name, then id.
    func recipes() throws -> [RecipeData]
}

extension FoodCatalogStore {
    /// `editFood(_:forkID:at:)` with a fresh random fork id.
    @discardableResult
    public func editFood(_ edited: FoodItemData, at date: Date) throws -> FoodItemData {
        try editFood(edited, forkID: UUID(), at: date)
    }
}

/// Plates (spec §1 MealEntry, MealItem, PhotoAttachment, AIEstimationRecord).
@MainActor
public protocol MealStore: AnyObject {
    /// Inserts a whole plate as given, snapshots included (a new draft, a
    /// watch marker, an import). Validates every id, reference and item shape,
    /// the hunger range, and that `loggedAt` is set exactly when the state
    /// is `.logged`, before inserting anything.
    func createMeal(_ meal: MealEntryData) throws
    func meal(id: UUID) throws -> MealEntryData?
    /// Every meal, by `createdAt`, then id.
    func meals() throws -> [MealEntryData]
    /// Logged meals whose `loggedAt` is in `[interval.start, interval.end)`,
    /// by `loggedAt`, then id.
    func loggedMeals(in interval: DateInterval) throws -> [MealEntryData]

    /// Adds an item after the plate's last one. A catalog item's snapshot
    /// is the food's current per-100 g values scaled to the quantity; an
    /// ad-hoc item stores its typed values. Returns the stored item.
    @discardableResult
    func addItem(_ item: MealItemInput, toMeal mealID: UUID) throws -> MealItemData
    func removeItem(id: UUID) throws
    func setHunger(_ hunger: Int?, mealID: UUID) throws
    func setNote(_ note: String?, mealID: UUID) throws
    func addPhoto(_ photo: PhotoAttachmentData, toMeal mealID: UUID) throws

    /// Draft → logged at `loggedAt` (late logging allowed). Updates each
    /// catalog food's typeahead fields: `useCount` +1 per item; and, when
    /// `loggedAt` is not older than the food's `lastUsedAt`, `lastUsedAt`
    /// and `lastPortionGrams` (from the plate's last item of that food).
    /// Snapshots are not recomputed. Throws `mealNotDraft` if logged.
    @discardableResult
    func logMeal(id: UUID, at loggedAt: Date) throws -> MealEntryData
    func deleteMeal(id: UUID) throws

    /// Throws `duplicateID`, or `missingPhoto` for an unknown `photoID`.
    func createAIEstimation(_ record: AIEstimationRecordData) throws
    func aiEstimation(id: UUID) throws -> AIEstimationRecordData?
}

/// GLP-1 lane (spec §1 ShotEvent, MedicationProfile, SideEffectEntry).
@MainActor
public protocol MedicationStore: AnyObject {
    func createMedicationProfile(_ profile: MedicationProfileData) throws
    func medicationProfile(id: UUID) throws -> MedicationProfileData?
    /// Sorted by name, then id.
    func medicationProfiles(includingArchived: Bool) throws -> [MedicationProfileData]
    func archiveMedicationProfile(id: UUID, at date: Date) throws

    /// Throws `duplicateID` or `missingMedication`.
    func createShot(_ shot: ShotEventData) throws
    func shot(id: UUID) throws -> ShotEventData?
    /// By `takenAt`, then id.
    func shots() throws -> [ShotEventData]
    /// Native shots only; the stored `source` is never changed.
    func updateShot(_ shot: ShotEventData) throws
    /// Native shots only.
    func deleteShot(id: UUID) throws

    /// Throws `duplicateID` or `invalidSeverity`.
    func createSideEffect(_ entry: SideEffectEntryData) throws
    /// By `occurredAt`, then id.
    func sideEffects() throws -> [SideEffectEntryData]
    func deleteSideEffect(id: UUID) throws
}

/// Planner schema (spec §1 PlannedShot / PlannedMeal; mechanics §8).
@MainActor
public protocol PlannerStore: AnyObject {
    func createPlannedShot(_ plan: PlannedShotData) throws
    /// By `plannedAt`, then id.
    func plannedShots() throws -> [PlannedShotData]
    func createPlannedMeal(_ plan: PlannedMealData) throws
    /// By `plannedAt`, then id.
    func plannedMeals() throws -> [PlannedMealData]
}

/// Timeline notes (spec §1 JournalEntry).
@MainActor
public protocol JournalStore: AnyObject {
    func createJournalEntry(_ entry: JournalEntryData) throws
    /// By `at`, then id.
    func journalEntries() throws -> [JournalEntryData]
    /// Cascades the entry's photos.
    func deleteJournalEntry(id: UUID) throws
}
