// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #1: create foods → draft plate → add items (catalog +
// ad-hoc) → log → shot + side effect + planned items → cold-load → graph
// identical. Expected values are worked by hand in the comments.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

/// Synthetic scenario ids.
enum RT {
    static let bread = uid(101)
    static let apple = uid(102)
    static let oatDrink = uid(103)
    static let porridge = uid(150)
    static let lunch = uid(201)
    static let marker = uid(202)
    static let breadItem = uid(211)
    static let soupItem = uid(212)
    static let lunchPhoto = uid(301)
    static let journalPhoto = uid(302)
    static let estimate = uid(401)
    static let medication = uid(500)
    static let shot = uid(501)
    static let headache = uid(601)
    static let nausea = uid(602)
    static let plannedShot = uid(701)
    static let plannedMeal = uid(702)
    static let journal = uid(801)
}

/// Runs the whole acceptance #1 flow through the protocol only.
@MainActor
func populateRoundTripScenario(_ store: some FreeLunchStore) throws {
    // Foods.
    try store.createFood(FoodItemData(
        id: RT.bread, name: "Rye bread", per100g: nutrition(250, 10, 30, 10, fiber: 5),
        servings: [ServingDef(name: "1 slice", grams: Grams(32))], origin: .seeded
    ))
    try store.createFood(FoodItemData(
        id: RT.apple, name: "Apple", per100g: nutrition(52, 0.25, 14, 0.5), origin: .custom
    ))
    try store.createFood(FoodItemData(
        id: RT.oatDrink, name: "Oat drink", brand: "Synthetic Co", per100g: nutrition(40, 1, 6.5, 1.5),
        isLiquid: true, origin: .labelOCR
    ))
    try store.createRecipe(RecipeData(
        id: RT.porridge, name: "Porridge",
        components: [
            RecipeComponentData(id: uid(151), foodID: RT.oatDrink, grams: Grams(250)),
            RecipeComponentData(id: uid(152), foodID: RT.apple, grams: Grams(100))
        ],
        yield: Grams(400)
    ))

    // Draft plate, photo, AI estimate, catalog + ad-hoc items, log.
    try store.createMeal(MealEntryData(id: RT.lunch, createdAt: at(hour: 4), hunger: 3, source: .phone))
    try store.addPhoto(
        PhotoAttachmentData(id: RT.lunchPhoto, relativePath: "photos/lunch.heic", capturedAt: at(hour: 4), kind: .meal),
        toMeal: RT.lunch
    )
    try store.createAIEstimation(AIEstimationRecordData(
        id: RT.estimate, createdAt: at(hour: 4), photoID: RT.lunchPhoto, hint: "bowl of soup",
        providerTier: 1, modelID: "synthetic-model", status: .complete,
        responseJSON: Data(#"{"items":1}"#.utf8), userCorrections: ["bigger bowl"]
    ))
    try store.addItem(
        .catalog(id: RT.breadItem, foodID: RT.bread, quantity: Grams(150), provenance: .scaleWeighed),
        toMeal: RT.lunch
    )
    try store.addItem(
        MealItemInput(
            id: RT.soupItem,
            kind: .adHoc(name: "Soup", nutrition: nutrition(120, 3, 20, 2.5, fiber: 1)),
            quantity: Grams(300),
            provenance: .aiEstimate,
            aiRecordID: RT.estimate,
            confidence: 0.75
        ),
        toMeal: RT.lunch
    )
    try store.setNote("synthetic lunch", mealID: RT.lunch)
    try store.logMeal(id: RT.lunch, at: at(hour: 5))

    // A watch quick-meal marker: a draft with no items.
    try store.createMeal(MealEntryData(id: RT.marker, createdAt: at(hour: 9), hunger: 4, source: .watchMarker))

    // GLP-1 lane.
    try store.createMedicationProfile(MedicationProfileData(id: RT.medication, known: .semaglutide))
    try store.createShot(ShotEventData(
        id: RT.shot, takenAt: at(hour: 1), dose: Milligrams(0.25), medicationID: RT.medication,
        site: .abdomenLeft, note: "synthetic", source: .phone
    ))
    try store.createSideEffect(SideEffectEntryData(id: RT.headache, occurredAt: at(hour: 6), type: .other("headache"), severity: 2))
    try store.createSideEffect(SideEffectEntryData(id: RT.nausea, occurredAt: at(hour: 7), type: .nausea, severity: 1, note: "mild"))

    // Planner.
    try store.createPlannedShot(PlannedShotData(
        id: RT.plannedShot, plannedAt: at(day: 7, hour: 1), notificationID: "n-701", dose: Milligrams(0.5)
    ))
    try store.createPlannedMeal(PlannedMealData(id: RT.plannedMeal, plannedAt: at(day: 1, hour: 4), name: "Lunch"))

    // Journal.
    try store.createJournalEntry(JournalEntryData(
        id: RT.journal, at: at(hour: 10), text: "Synthetic note",
        photos: [PhotoAttachmentData(id: RT.journalPhoto, relativePath: "photos/note.heic", capturedAt: at(hour: 10), kind: .label)]
    ))
}

@MainActor
@Suite("Spec §1 acceptance #1: round-trip")
struct RoundTripTests {
    /// The hand-computed facts the reloaded graph must carry.
    func expectScenarioValues(_ graph: StoreGraph) throws {
        #expect(graph.foods.map(\.name) == ["Apple", "Oat drink", "Rye bread"])

        let bread = try #require(graph.foods.first { $0.id == RT.bread })
        // Typeahead at log time: one use, at 05:00, 150 g.
        #expect(bread.useCount == 1)
        #expect(bread.lastUsedAt == at(hour: 5))
        #expect(bread.lastPortionGrams == 150)
        #expect(bread.servings == [ServingDef(name: "1 slice", grams: Grams(32))])
        let apple = try #require(graph.foods.first { $0.id == RT.apple })
        #expect(apple.useCount == 0 && apple.lastUsedAt == nil && apple.lastPortionGrams == nil)

        #expect(graph.meals.map(\.id) == [RT.lunch, RT.marker])
        let lunch = graph.meals[0]
        #expect(lunch.state == .logged)
        #expect(lunch.createdAt == at(hour: 4))
        #expect(lunch.loggedAt == at(hour: 5))
        #expect(lunch.hunger == 3)
        #expect(lunch.note == "synthetic lunch")
        #expect(lunch.source == .phone)
        #expect(lunch.photos.map(\.id) == [RT.lunchPhoto])
        #expect(lunch.items.map(\.id) == [RT.breadItem, RT.soupItem])
        #expect(lunch.items.map(\.order) == [0, 1])

        // 150 g of 250/10/30/10/5 per 100 g: 375 kcal, 15 P, 45 C, 15 F, 7.5 fiber.
        let breadItem = lunch.items[0]
        #expect(breadItem.foodID == RT.bread)
        #expect(breadItem.adHocName == nil)
        #expect(breadItem.quantityGrams == 150)
        #expect(sameBits(breadItem.nutrition, nutrition(375, 15, 45, 15, fiber: 7.5)))
        #expect(breadItem.provenance == .scaleWeighed)

        let soup = lunch.items[1]
        #expect(soup.foodID == nil)
        #expect(soup.adHocName == "Soup")
        #expect(soup.quantityGrams == 300)
        #expect(sameBits(soup.nutrition, nutrition(120, 3, 20, 2.5, fiber: 1)))
        #expect(soup.provenance == .aiEstimate)
        #expect(soup.aiRecordID == RT.estimate)
        #expect(soup.confidence == 0.75)

        let marker = graph.meals[1]
        #expect(marker.state == .draft && marker.items.isEmpty && marker.source == .watchMarker && marker.hunger == 4)

        let estimate = try #require(graph.aiRecords.first)
        #expect(estimate.photoID == RT.lunchPhoto)
        #expect(estimate.status == .complete)
        #expect(estimate.responseJSON == Data(#"{"items":1}"#.utf8))
        #expect(estimate.userCorrections == ["bigger bowl"])

        let porridge = try #require(graph.recipes.first)
        #expect(porridge.components.map(\.foodID) == [RT.oatDrink, RT.apple])
        #expect(porridge.yieldGrams == 400)

        #expect(graph.profiles == [MedicationProfileData(id: RT.medication, known: .semaglutide)])
        let shot = try #require(graph.shots.first)
        #expect(shot.doseMg == 0.25 && shot.medicationID == RT.medication && shot.site == .abdomenLeft)
        #expect(graph.sideEffects.map(\.type) == [.other("headache"), .nausea])
        #expect(graph.sideEffects.map(\.severity) == [2, 1])
        #expect(graph.plannedShots.first?.doseMg == 0.5)
        #expect(graph.plannedShots.first?.status == .pending)
        #expect(graph.plannedMeals.first?.name == "Lunch")
        #expect(graph.journal.first?.photos.map(\.id) == [RT.journalPhoto])
    }

    @Test("in-memory container: a second store on the same container reads the identical graph")
    func inMemoryRoundTrip() throws {
        let container = try FreeLunchContainer.make(.phone, at: .inMemory)
        let writer = SwiftDataStore(container: container)
        try populateRoundTripScenario(writer)
        let written = try StoreGraph(writer, aiRecordIDs: [RT.estimate])

        let reader = SwiftDataStore(container: container)
        let reloaded = try StoreGraph(reader, aiRecordIDs: [RT.estimate])

        #expect(reloaded == written)
        try expectScenarioValues(reloaded)
    }

    @Test("file store: closing and reopening through the migration plan reads the identical graph")
    func fileColdLoad() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }

        let written: StoreGraph
        do {
            let writer = try SwiftDataStore.phone(at: .file(url))
            try populateRoundTripScenario(writer)
            written = try StoreGraph(writer, aiRecordIDs: [RT.estimate])
        }

        let reader = try SwiftDataStore.phone(at: .file(url))
        let reloaded = try StoreGraph(reader, aiRecordIDs: [RT.estimate])
        #expect(reloaded == written)
        try expectScenarioValues(reloaded)
    }

    @Test("recipe per-100 g nutrition is components ÷ yield")
    func recipeNutrition() throws {
        let store = try makeInMemoryStore()
        try populateRoundTripScenario(store)
        let foods = Dictionary(uniqueKeysWithValues: try store.foods(includingArchived: true).map { ($0.id, $0) })
        let porridge = try #require(try store.recipe(id: RT.porridge))
        // 250 g oat drink: 100 kcal, 2.5 P, 16.25 C, 3.75 F
        // 100 g apple:      52 kcal, 0.25 P, 14 C,   0.5 F
        // sum: 152 / 2.75 / 30.25 / 4.25, × 100 ÷ 400 g yield:
        let per100 = try #require(porridge.nutritionPer100g(resolving: foods))
        #expect(sameBits(per100, nutrition(38, 0.6875, 7.5625, 1.0625)))
    }
}
