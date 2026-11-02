// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #4: deleting a MealEntry removes its items and photos;
// FoodItems and other meals are untouched; an archived FoodItem stays
// resolvable from history. Plus the integrity rules around it: imported
// records never mutate, and nothing in the store API deletes a food.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §1 acceptance #4: cascade and archive")
struct CascadeAndArchiveTests {
    let rice = uid(120)
    let beans = uid(121)
    let doomed = uid(260)
    let kept = uid(270)
    let sharedEstimate = uid(410)
    let ownEstimate = uid(411)

    /// `doomed`: 3 items (rice, beans, ad-hoc), 2 photos, its own AI
    /// estimate on photo 1, and an item using a shared estimate.
    /// `kept`: 1 rice item using the shared estimate, 1 photo.
    func populate(_ store: some FreeLunchStore) throws {
        try store.createFood(FoodItemData(id: rice, name: "Rice", per100g: nutrition(130, 2.5, 28, 0.25), origin: .seeded))
        try store.createFood(FoodItemData(id: beans, name: "Beans", per100g: nutrition(120, 8, 20, 0.5, fiber: 6), origin: .seeded))

        try store.createMeal(MealEntryData(id: kept, createdAt: at(hour: 1), source: .phone))
        try store.addPhoto(PhotoAttachmentData(id: uid(330), relativePath: "p/kept.heic", capturedAt: at(hour: 1), kind: .meal), toMeal: kept)
        try store.createAIEstimation(AIEstimationRecordData(id: sharedEstimate, createdAt: at(hour: 1), photoID: uid(330), providerTier: 2, modelID: "synthetic"))
        var keptRice = MealItemInput.catalog(id: uid(271), foodID: rice, quantity: Grams(200), provenance: .aiEstimate)
        keptRice.aiRecordID = sharedEstimate
        try store.addItem(keptRice, toMeal: kept)
        try store.logMeal(id: kept, at: at(hour: 1))

        try store.createMeal(MealEntryData(id: doomed, createdAt: at(hour: 3), source: .phone))
        try store.addPhoto(PhotoAttachmentData(id: uid(310), relativePath: "p/1.heic", capturedAt: at(hour: 3), kind: .meal), toMeal: doomed)
        try store.addPhoto(PhotoAttachmentData(id: uid(311), relativePath: "p/2.heic", capturedAt: at(hour: 3), kind: .label), toMeal: doomed)
        try store.createAIEstimation(AIEstimationRecordData(id: ownEstimate, createdAt: at(hour: 3), photoID: uid(310), providerTier: 1, modelID: "synthetic"))
        try store.addItem(.catalog(id: uid(261), foodID: rice, quantity: Grams(100)), toMeal: doomed)
        try store.addItem(.catalog(id: uid(262), foodID: beans, quantity: Grams(50)), toMeal: doomed)
        var shared = MealItemInput.adHoc(id: uid(263), name: "Salsa", quantity: Grams(30), nutrition: nutrition(10, 0.5, 2, 0))
        shared.aiRecordID = sharedEstimate
        try store.addItem(shared, toMeal: doomed)
        try store.logMeal(id: doomed, at: at(hour: 3))
    }

    @Test("deleting a meal removes exactly its items and photos; foods and the other meal are untouched")
    func deleteCascades() throws {
        let container = try FreeLunchContainer.make(.phone, at: .inMemory)
        let store = SwiftDataStore(container: container)
        try populate(store)

        #expect(try store.rowCount(MealEntry.self) == 2)
        #expect(try store.rowCount(MealItem.self) == 4)
        #expect(try store.rowCount(PhotoAttachment.self) == 3)
        #expect(try store.rowCount(FoodItem.self) == 2)
        #expect(try store.rowCount(AIEstimationRecord.self) == 2)
        let foodsBefore = try store.foods(includingArchived: true)
        let keptBefore = try #require(try store.meal(id: kept))

        try store.deleteMeal(id: doomed)

        let reader = SwiftDataStore(container: container)
        #expect(try reader.meal(id: doomed) == nil)
        #expect(try reader.rowCount(MealEntry.self) == 1)
        #expect(try reader.rowCount(MealItem.self) == 1)
        #expect(try reader.rowCount(PhotoAttachment.self) == 1)
        #expect(try reader.rowCount(FoodItem.self) == 2)
        #expect(try reader.foods(includingArchived: true) == foodsBefore)
        #expect(try reader.meal(id: kept) == keptBefore)

        // The doomed meal's own estimate goes; the shared one stays because
        // the kept meal still uses it.
        #expect(try reader.aiEstimation(id: ownEstimate) == nil)
        #expect(try reader.aiEstimation(id: sharedEstimate)?.photoID == uid(330))
        #expect(try reader.rowCount(AIEstimationRecord.self) == 1)
    }

    @Test("an archived food is hidden from typeahead but resolves from history")
    func archivedFoodResolves() throws {
        let store = try makeInMemoryStore()
        try populate(store)
        try store.archiveFood(id: rice, at: at(day: 5))

        #expect(try store.foods(includingArchived: false).map(\.id) == [beans])
        #expect(try store.foods(includingArchived: true).map(\.id).sorted { $0.uuidString < $1.uuidString } == [rice, beans])

        try store.deleteMeal(id: doomed)
        let keptItem = try #require(try store.meal(id: kept)?.items.first)
        let foodID = try #require(keptItem.foodID)
        let resolved = try #require(try store.food(id: foodID))
        #expect(resolved.id == rice)
        #expect(resolved.name == "Rice")
        #expect(resolved.archivedAt == at(day: 5))
        // 200 g rice at 130/2.5/28/0.25: 260 kcal, 5 P, 56 C, 0.5 F.
        #expect(sameBits(keptItem.nutrition, nutrition(260, 5, 56, 0.5)))
    }

    @Test("a journal entry delete cascades its photos only")
    func journalCascade() throws {
        let store = try makeInMemoryStore()
        try populate(store)
        try store.createJournalEntry(JournalEntryData(
            id: uid(820), at: at(hour: 5), text: "note",
            photos: [PhotoAttachmentData(id: uid(321), relativePath: "p/j.heic", capturedAt: at(hour: 5), kind: .meal)]
        ))
        #expect(try store.rowCount(PhotoAttachment.self) == 4)
        try store.deleteJournalEntry(id: uid(820))
        #expect(try store.rowCount(PhotoAttachment.self) == 3)
        #expect(try store.journalEntries().isEmpty)
    }

    @Test("imported meals and shots never mutate")
    func importedRecordsImmutable() throws {
        let store = try makeInMemoryStore()
        try store.createFood(FoodItemData(id: rice, name: "Rice", per100g: nutrition(130, 2.5, 28, 0.25), origin: .imported))
        let imported = uid(280)
        try store.createMeal(MealEntryData(
            id: imported, state: .logged, createdAt: at(hour: 2), loggedAt: at(hour: 2),
            items: [MealItemData(id: uid(281), order: 0, foodID: nil, adHocName: "Imported day", quantity: Grams(0),
                                 nutrition: nutrition(1800, 90, 200, 60), provenance: .imported)],
            source: .healthKitImport
        ))
        let before = try store.meal(id: imported)

        #expect(throws: FreeLunchStoreError.importedRecordImmutable(imported)) { try store.deleteMeal(id: imported) }
        #expect(throws: FreeLunchStoreError.importedRecordImmutable(imported)) { try store.removeItem(id: uid(281)) }
        #expect(throws: FreeLunchStoreError.importedRecordImmutable(imported)) { try store.setHunger(2, mealID: imported) }
        #expect(throws: FreeLunchStoreError.importedRecordImmutable(imported)) {
            try store.addItem(.catalog(foodID: rice, quantity: Grams(10)), toMeal: imported)
        }
        #expect(try store.meal(id: imported) == before)

        try store.createMedicationProfile(MedicationProfileData(id: uid(510), known: .tirzepatide))
        let shot = ShotEventData(id: uid(511), takenAt: at(), dose: Milligrams(2.5), medicationID: uid(510), source: .shotsyImport)
        try store.createShot(shot)
        var edited = shot
        edited.setDose(Milligrams(5))
        #expect(throws: FreeLunchStoreError.importedRecordImmutable(uid(511))) { try store.updateShot(edited) }
        #expect(throws: FreeLunchStoreError.importedRecordImmutable(uid(511))) { try store.deleteShot(id: uid(511)) }
        #expect(try store.shot(id: uid(511)) == shot)
    }

    @Test("native shots edit and delete freely")
    func nativeShotsEditable() throws {
        let store = try makeInMemoryStore()
        try store.createMedicationProfile(MedicationProfileData(id: uid(510), known: .tirzepatide))
        var shot = ShotEventData(id: uid(512), takenAt: at(), dose: Milligrams(2.5), medicationID: uid(510), source: .watch)
        try store.createShot(shot)
        shot.setDose(Milligrams(5))
        shot.site = .thighRight
        try store.updateShot(shot)
        #expect(try store.shot(id: uid(512)) == shot)
        try store.deleteShot(id: uid(512))
        #expect(try store.shots().isEmpty)
    }

    @Test("refused writes leave the store unchanged")
    func refusalsAreAtomic() throws {
        let store = try makeInMemoryStore()
        try populate(store)
        let before = try StoreGraph(store, aiRecordIDs: [sharedEstimate, ownEstimate])

        // Second item references a missing food: nothing of the meal lands.
        let bad = MealEntryData(
            id: uid(290), createdAt: at(day: 1),
            items: [
                MealItemData(id: uid(291), order: 0, foodID: rice, quantity: Grams(10), nutrition: nutrition(13, 0.25, 2.8, 0.025), provenance: .typed),
                MealItemData(id: uid(292), order: 1, foodID: uid(999), quantity: Grams(10), nutrition: nutrition(1, 0, 0, 0), provenance: .typed)
            ],
            hunger: 2,
            source: .phone
        )
        #expect(throws: FreeLunchStoreError.missingFood(uid(999))) { try store.createMeal(bad) }
        #expect(throws: FreeLunchStoreError.invalidHunger(6)) {
            try store.createMeal(MealEntryData(id: uid(293), createdAt: at(), hunger: 6, source: .phone))
        }
        #expect(throws: FreeLunchStoreError.invalidHunger(0)) { try store.setHunger(0, mealID: kept) }
        #expect(throws: FreeLunchStoreError.duplicateID(rice)) {
            try store.createFood(FoodItemData(id: rice, name: "Dup", per100g: nutrition(1, 1, 1, 1), origin: .custom))
        }
        #expect(throws: FreeLunchStoreError.mealNotDraft(kept)) { try store.logMeal(id: kept, at: at(day: 2)) }
        #expect(throws: FreeLunchStoreError.invalidSeverity(4)) {
            try store.createSideEffect(SideEffectEntryData(occurredAt: at(), type: .fatigue, severity: 4))
        }
        #expect(throws: FreeLunchStoreError.missingMedication(uid(998))) {
            try store.createShot(ShotEventData(takenAt: at(), dose: Milligrams(1), medicationID: uid(998)))
        }
        #expect(throws: FreeLunchStoreError.invalidItem(uid(294))) {
            try store.createMeal(MealEntryData(
                id: uid(295), createdAt: at(),
                items: [MealItemData(id: uid(294), order: 0, foodID: nil, quantity: Grams(1), nutrition: nutrition(1, 0, 0, 0), provenance: .typed)],
                source: .phone
            ))
        }

        #expect(try StoreGraph(store, aiRecordIDs: [sharedEstimate, ownEstimate]) == before)
        #expect(try store.rowCount(MealItem.self) == 4)
    }
}
