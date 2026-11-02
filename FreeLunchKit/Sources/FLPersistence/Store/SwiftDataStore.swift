// SPDX-License-Identifier: GPL-3.0-or-later
// SwiftDataStore — the SwiftData conformer of `FreeLunchStore`.
//
// Autosave is off. Every mutating method validates everything first, then
// inserts or mutates, then saves through `commit()`, which rolls the context
// back if the save fails, so a refused or failed call leaves nothing staged
// for a later save to commit.
//
// Lists are fetched whole and sorted in Swift: the data is small, and
// predicates over optional dates and enums are a SwiftData sharp edge.
import FLCore
import Foundation
import SwiftData

@MainActor
public final class SwiftDataStore: FreeLunchStore {
    let context: ModelContext

    /// Internal: `ModelContainer` never appears in a public signature (see
    /// Schema/FreeLunchContainer.swift). Tests reach it through
    /// `@testable import` to open a second store on the same container.
    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public convenience init(kind: FreeLunchStoreKind, at location: FreeLunchStoreLocation = .applicationDefault) throws {
        self.init(container: try FreeLunchContainer.make(kind, at: location))
    }

    /// Phone store: full history (spec §1 store shape).
    public static func phone(at location: FreeLunchStoreLocation = .applicationDefault) throws -> SwiftDataStore {
        try SwiftDataStore(kind: .phone, at: location)
    }

    /// Watch store: working set only (spec §1 store shape).
    public static func watch(at location: FreeLunchStoreLocation = .applicationDefault) throws -> SwiftDataStore {
        try SwiftDataStore(kind: .watch, at: location)
    }

    // MARK: - Foods

    public func createFood(_ food: FoodItemData) throws {
        guard try model(FoodItem.self, id: food.id) == nil else {
            throw FreeLunchStoreError.duplicateID(food.id)
        }
        let servings = try ServingsCoding.encode(food.servings)
        context.insert(
            FoodItem(
                id: food.id,
                name: food.name,
                brand: food.brand,
                kcal: food.per100g.kcal,
                proteinG: food.per100g.proteinG,
                carbsG: food.per100g.carbsG,
                fatG: food.per100g.fatG,
                fiberG: food.per100g.fiberG,
                isLiquid: food.isLiquid,
                servingsJSON: servings,
                origin: food.origin,
                useCount: food.useCount,
                lastUsedAt: food.lastUsedAt,
                lastPortionGrams: food.lastPortionGrams,
                archivedAt: food.archivedAt
            )
        )
        try commit()
    }

    public func food(id: UUID) throws -> FoodItemData? {
        try model(FoodItem.self, id: id)?.asData()
    }

    public func foods(includingArchived: Bool) throws -> [FoodItemData] {
        try context.fetch(FetchDescriptor<FoodItem>())
            .filter { includingArchived || $0.archivedAt == nil }
            .map { try $0.asData() }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func updateFood(_ food: FoodItemData) throws {
        guard let stored = try model(FoodItem.self, id: food.id) else {
            throw FreeLunchStoreError.notFound(food.id)
        }
        let servings = try ServingsCoding.encode(food.servings)
        stored.name = food.name
        stored.brand = food.brand
        stored.kcal = food.per100g.kcal
        stored.proteinG = food.per100g.proteinG
        stored.carbsG = food.per100g.carbsG
        stored.fatG = food.per100g.fatG
        stored.fiberG = food.per100g.fiberG
        stored.isLiquid = food.isLiquid
        stored.servingsJSON = servings
        stored.origin = food.origin
        try commit()
    }

    public func archiveFood(id: UUID, at date: Date) throws {
        guard let stored = try model(FoodItem.self, id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        stored.archivedAt = date
        try commit()
    }

    // MARK: - Recipes

    public func createRecipe(_ recipe: RecipeData) throws {
        guard try model(Recipe.self, id: recipe.id) == nil else {
            throw FreeLunchStoreError.duplicateID(recipe.id)
        }
        guard recipe.yieldGrams > 0 else { throw FreeLunchStoreError.invalidYield(recipe.id) }
        var seen: Set<UUID> = []
        var foods: [FoodItem] = []
        for component in recipe.components {
            guard seen.insert(component.id).inserted,
                  try model(RecipeComponent.self, id: component.id) == nil
            else {
                throw FreeLunchStoreError.duplicateID(component.id)
            }
            guard let food = try model(FoodItem.self, id: component.foodID) else {
                throw FreeLunchStoreError.missingFood(component.foodID)
            }
            foods.append(food)
        }

        let stored = Recipe(id: recipe.id, name: recipe.name, yieldGrams: recipe.yieldGrams)
        context.insert(stored)
        for (index, component) in recipe.components.enumerated() {
            let row = RecipeComponent(id: component.id, order: index, grams: component.grams, foodItem: foods[index])
            context.insert(row)
            row.recipe = stored
        }
        try commit()
    }

    public func recipe(id: UUID) throws -> RecipeData? {
        try model(Recipe.self, id: id)?.asData()
    }

    public func recipes() throws -> [RecipeData] {
        try context.fetch(FetchDescriptor<Recipe>())
            .map { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    // MARK: - Meals

    public func createMeal(_ meal: MealEntryData) throws {
        guard try model(MealEntry.self, id: meal.id) == nil else {
            throw FreeLunchStoreError.duplicateID(meal.id)
        }
        try validateHunger(meal.hunger)
        // A logged meal without a time would never count toward a day total.
        guard (meal.state == .logged) == (meal.loggedAt != nil) else {
            throw FreeLunchStoreError.invalidMealState(meal.id)
        }

        var itemIDs: Set<UUID> = []
        var resolved: [(food: FoodItem?, aiRecord: AIEstimationRecord?)] = []
        for item in meal.items {
            guard itemIDs.insert(item.id).inserted, try model(MealItem.self, id: item.id) == nil else {
                throw FreeLunchStoreError.duplicateID(item.id)
            }
            resolved.append(try resolveItem(item))
        }
        try preflightPhotos(meal.photos)

        let stored = MealEntry(
            id: meal.id,
            state: meal.state,
            createdAt: meal.createdAt,
            loggedAt: meal.loggedAt,
            hunger: meal.hunger,
            note: meal.note,
            source: meal.source
        )
        context.insert(stored)
        for (item, links) in zip(meal.items, resolved) {
            let row = makeItem(item, food: links.food, aiRecord: links.aiRecord)
            context.insert(row)
            row.meal = stored
        }
        for photo in meal.photos {
            let row = makePhoto(photo)
            context.insert(row)
            row.meal = stored
        }
        try commit()
    }

    public func meal(id: UUID) throws -> MealEntryData? {
        try model(MealEntry.self, id: id)?.asData()
    }

    public func meals() throws -> [MealEntryData] {
        try context.fetch(FetchDescriptor<MealEntry>())
            .map { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func loggedMeals(in interval: DateInterval) throws -> [MealEntryData] {
        try context.fetch(FetchDescriptor<MealEntry>())
            .filter { meal in
                guard meal.state == .logged, let loggedAt = meal.loggedAt else { return false }
                return loggedAt >= interval.start && loggedAt < interval.end
            }
            .map { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.loggedAt != rhs.loggedAt { return lhs.loggedAt! < rhs.loggedAt! }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    @discardableResult
    public func addItem(_ input: MealItemInput, toMeal mealID: UUID) throws -> MealItemData {
        let meal = try editableMeal(id: mealID)
        guard try model(MealItem.self, id: input.id) == nil else {
            throw FreeLunchStoreError.duplicateID(input.id)
        }
        var aiRecord: AIEstimationRecord?
        if let aiRecordID = input.aiRecordID {
            guard let record = try model(AIEstimationRecord.self, id: aiRecordID) else {
                throw FreeLunchStoreError.missingAIRecord(aiRecordID)
            }
            aiRecord = record
        }

        let food: FoodItem?
        let adHocName: String?
        let snapshot: NutritionValues
        switch input.kind {
        case .catalog(let foodID):
            guard let stored = try model(FoodItem.self, id: foodID) else {
                throw FreeLunchStoreError.missingFood(foodID)
            }
            food = stored
            adHocName = nil
            snapshot = try stored.asData().nutrition(for: input.quantity)
        case .adHoc(let name, let nutrition):
            food = nil
            adHocName = name
            snapshot = nutrition
        }

        let order = (meal.items.map(\.order).max() ?? -1) + 1
        let item = MealItemData(
            id: input.id,
            order: order,
            foodID: food?.id,
            adHocName: adHocName,
            quantity: input.quantity,
            nutrition: snapshot,
            provenance: input.provenance,
            aiRecordID: aiRecord?.id,
            confidence: input.confidence
        )
        let row = makeItem(item, food: food, aiRecord: aiRecord)
        context.insert(row)
        row.meal = meal
        try commit()
        return item
    }

    public func removeItem(id: UUID) throws {
        guard let item = try model(MealItem.self, id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        if let meal = item.meal, meal.source == .healthKitImport {
            throw FreeLunchStoreError.importedRecordImmutable(meal.id)
        }
        context.delete(item)
        try commit()
    }

    public func setHunger(_ hunger: Int?, mealID: UUID) throws {
        let meal = try editableMeal(id: mealID)
        try validateHunger(hunger)
        meal.hunger = hunger
        try commit()
    }

    public func setNote(_ note: String?, mealID: UUID) throws {
        let meal = try editableMeal(id: mealID)
        meal.note = note
        try commit()
    }

    public func addPhoto(_ photo: PhotoAttachmentData, toMeal mealID: UUID) throws {
        let meal = try editableMeal(id: mealID)
        try preflightPhotos([photo])
        let row = makePhoto(photo)
        context.insert(row)
        row.meal = meal
        try commit()
    }

    @discardableResult
    public func logMeal(id: UUID, at loggedAt: Date) throws -> MealEntryData {
        let meal = try editableMeal(id: id)
        guard meal.state == .draft else { throw FreeLunchStoreError.mealNotDraft(id) }

        meal.state = .logged
        meal.loggedAt = loggedAt
        let ordered = meal.items.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // Typeahead denormalization (spec §1), maintained at log time.
        // Recency fields follow the most recent use, so a late log of an
        // older plate does not overwrite a newer portion.
        var counted: Set<UUID> = []
        for item in ordered {
            guard let food = item.foodItem else { continue }
            food.useCount += 1
            counted.insert(food.id)
        }
        for item in ordered.reversed() {
            guard let food = item.foodItem, counted.remove(food.id) != nil else { continue }
            if food.lastUsedAt.map({ loggedAt >= $0 }) ?? true {
                food.lastUsedAt = loggedAt
                food.lastPortionGrams = item.quantityGrams
            }
        }
        try commit()
        return meal.asData()
    }

    public func deleteMeal(id: UUID) throws {
        let meal = try editableMeal(id: id)

        // AI records this plate alone used: referenced by its items or
        // linked to its photos, and by no other meal's item.
        var candidates: [UUID: AIEstimationRecord] = [:]
        for item in meal.items {
            if let record = item.aiRecord { candidates[record.id] = record }
        }
        for photo in meal.photos {
            for record in photo.aiRecords { candidates[record.id] = record }
        }
        let orphaned = candidates.values.filter { record in
            record.items.allSatisfy { $0.meal?.id == id }
        }

        for record in orphaned {
            context.delete(record)
        }
        context.delete(meal)
        try commit()
    }

    public func createAIEstimation(_ record: AIEstimationRecordData) throws {
        guard try model(AIEstimationRecord.self, id: record.id) == nil else {
            throw FreeLunchStoreError.duplicateID(record.id)
        }
        var photo: PhotoAttachment?
        if let photoID = record.photoID {
            guard let stored = try model(PhotoAttachment.self, id: photoID) else {
                throw FreeLunchStoreError.missingPhoto(photoID)
            }
            photo = stored
        }
        context.insert(
            AIEstimationRecord(
                id: record.id,
                createdAt: record.createdAt,
                photo: photo,
                hint: record.hint,
                providerTier: record.providerTier,
                modelID: record.modelID,
                status: record.status,
                responseJSON: record.responseJSON,
                userCorrections: record.userCorrections
            )
        )
        try commit()
    }

    public func aiEstimation(id: UUID) throws -> AIEstimationRecordData? {
        try model(AIEstimationRecord.self, id: id)?.asData()
    }

    // MARK: - Medication

    public func createMedicationProfile(_ profile: MedicationProfileData) throws {
        guard try model(MedicationProfile.self, id: profile.id) == nil else {
            throw FreeLunchStoreError.duplicateID(profile.id)
        }
        context.insert(
            MedicationProfile(
                id: profile.id,
                name: profile.name,
                halfLifeHours: profile.halfLifeHours,
                tmaxHours: profile.tmaxHours,
                intervalDays: profile.intervalDays,
                archivedAt: profile.archivedAt
            )
        )
        try commit()
    }

    public func medicationProfile(id: UUID) throws -> MedicationProfileData? {
        try model(MedicationProfile.self, id: id)?.asData()
    }

    public func medicationProfiles(includingArchived: Bool) throws -> [MedicationProfileData] {
        try context.fetch(FetchDescriptor<MedicationProfile>())
            .filter { includingArchived || $0.archivedAt == nil }
            .map { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func archiveMedicationProfile(id: UUID, at date: Date) throws {
        guard let stored = try model(MedicationProfile.self, id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        stored.archivedAt = date
        try commit()
    }

    public func createShot(_ shot: ShotEventData) throws {
        guard try model(ShotEvent.self, id: shot.id) == nil else {
            throw FreeLunchStoreError.duplicateID(shot.id)
        }
        guard let medication = try model(MedicationProfile.self, id: shot.medicationID) else {
            throw FreeLunchStoreError.missingMedication(shot.medicationID)
        }
        context.insert(
            ShotEvent(
                id: shot.id,
                takenAt: shot.takenAt,
                doseMg: shot.doseMg,
                medication: medication,
                siteRaw: shot.site?.rawValue,
                note: shot.note,
                source: shot.source
            )
        )
        try commit()
    }

    public func shot(id: UUID) throws -> ShotEventData? {
        try model(ShotEvent.self, id: id)?.asData()
    }

    public func shots() throws -> [ShotEventData] {
        try context.fetch(FetchDescriptor<ShotEvent>())
            .compactMap { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.takenAt != rhs.takenAt { return lhs.takenAt < rhs.takenAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func updateShot(_ shot: ShotEventData) throws {
        let stored = try nativeShot(id: shot.id)
        guard let medication = try model(MedicationProfile.self, id: shot.medicationID) else {
            throw FreeLunchStoreError.missingMedication(shot.medicationID)
        }
        stored.takenAt = shot.takenAt
        stored.doseMg = shot.doseMg
        stored.medication = medication
        stored.siteRaw = shot.site?.rawValue
        stored.note = shot.note
        try commit()
    }

    public func deleteShot(id: UUID) throws {
        context.delete(try nativeShot(id: id))
        try commit()
    }

    public func createSideEffect(_ entry: SideEffectEntryData) throws {
        guard try model(SideEffectEntry.self, id: entry.id) == nil else {
            throw FreeLunchStoreError.duplicateID(entry.id)
        }
        guard DomainScale.sideEffectSeverity.contains(entry.severity) else {
            throw FreeLunchStoreError.invalidSeverity(entry.severity)
        }
        let coded = SideEffectTypeCoding.kind(of: entry.type)
        context.insert(
            SideEffectEntry(
                id: entry.id,
                occurredAt: entry.occurredAt,
                typeKind: coded.kind,
                otherText: coded.text,
                severity: entry.severity,
                note: entry.note
            )
        )
        try commit()
    }

    public func sideEffects() throws -> [SideEffectEntryData] {
        try context.fetch(FetchDescriptor<SideEffectEntry>())
            .map { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func deleteSideEffect(id: UUID) throws {
        guard let stored = try model(SideEffectEntry.self, id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        context.delete(stored)
        try commit()
    }

    // MARK: - Planner

    public func createPlannedShot(_ plan: PlannedShotData) throws {
        guard try model(PlannedShot.self, id: plan.id) == nil else {
            throw FreeLunchStoreError.duplicateID(plan.id)
        }
        context.insert(
            PlannedShot(
                id: plan.id,
                plannedAt: plan.plannedAt,
                notificationID: plan.notificationID,
                status: plan.status,
                fulfilledBy: plan.fulfilledBy,
                doseMg: plan.doseMg
            )
        )
        try commit()
    }

    public func plannedShots() throws -> [PlannedShotData] {
        try context.fetch(FetchDescriptor<PlannedShot>())
            .map { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.plannedAt != rhs.plannedAt { return lhs.plannedAt < rhs.plannedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func createPlannedMeal(_ plan: PlannedMealData) throws {
        guard try model(PlannedMeal.self, id: plan.id) == nil else {
            throw FreeLunchStoreError.duplicateID(plan.id)
        }
        context.insert(
            PlannedMeal(
                id: plan.id,
                plannedAt: plan.plannedAt,
                notificationID: plan.notificationID,
                status: plan.status,
                fulfilledBy: plan.fulfilledBy,
                name: plan.name,
                note: plan.note
            )
        )
        try commit()
    }

    public func plannedMeals() throws -> [PlannedMealData] {
        try context.fetch(FetchDescriptor<PlannedMeal>())
            .map { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.plannedAt != rhs.plannedAt { return lhs.plannedAt < rhs.plannedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    // MARK: - Journal

    public func createJournalEntry(_ entry: JournalEntryData) throws {
        guard try model(JournalEntry.self, id: entry.id) == nil else {
            throw FreeLunchStoreError.duplicateID(entry.id)
        }
        try preflightPhotos(entry.photos)
        let stored = JournalEntry(id: entry.id, at: entry.at, text: entry.text)
        context.insert(stored)
        for photo in entry.photos {
            let row = makePhoto(photo)
            context.insert(row)
            row.journalEntry = stored
        }
        try commit()
    }

    public func journalEntries() throws -> [JournalEntryData] {
        try context.fetch(FetchDescriptor<JournalEntry>())
            .map { $0.asData() }
            .sorted { lhs, rhs in
                if lhs.at != rhs.at { return lhs.at < rhs.at }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func deleteJournalEntry(id: UUID) throws {
        guard let stored = try model(JournalEntry.self, id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        context.delete(stored)
        try commit()
    }

    // MARK: - Helpers

    func commit() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func model<T: PersistentModel & IdentifiedByUUID>(_ type: T.Type, id: UUID) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: T.predicate(id: id))
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// A stored meal that may be edited: native, not imported.
    func editableMeal(id: UUID) throws -> MealEntry {
        guard let meal = try model(MealEntry.self, id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        guard meal.source != .healthKitImport else {
            throw FreeLunchStoreError.importedRecordImmutable(id)
        }
        return meal
    }

    private func nativeShot(id: UUID) throws -> ShotEvent {
        guard let shot = try model(ShotEvent.self, id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        guard shot.source != .shotsyImport else {
            throw FreeLunchStoreError.importedRecordImmutable(id)
        }
        return shot
    }

    private func validateHunger(_ hunger: Int?) throws {
        if let hunger, !DomainScale.hunger.contains(hunger) {
            throw FreeLunchStoreError.invalidHunger(hunger)
        }
    }

    private func resolveItem(_ item: MealItemData) throws -> (food: FoodItem?, aiRecord: AIEstimationRecord?) {
        var food: FoodItem?
        switch (item.foodID, item.adHocName) {
        case (let foodID?, nil):
            guard let stored = try model(FoodItem.self, id: foodID) else {
                throw FreeLunchStoreError.missingFood(foodID)
            }
            food = stored
        case (nil, _?):
            food = nil
        default:
            throw FreeLunchStoreError.invalidItem(item.id)
        }
        var aiRecord: AIEstimationRecord?
        if let aiRecordID = item.aiRecordID {
            guard let record = try model(AIEstimationRecord.self, id: aiRecordID) else {
                throw FreeLunchStoreError.missingAIRecord(aiRecordID)
            }
            aiRecord = record
        }
        return (food, aiRecord)
    }

    private func preflightPhotos(_ photos: [PhotoAttachmentData]) throws {
        var seen: Set<UUID> = []
        for photo in photos {
            guard seen.insert(photo.id).inserted, try model(PhotoAttachment.self, id: photo.id) == nil else {
                throw FreeLunchStoreError.duplicateID(photo.id)
            }
        }
    }

    private func makeItem(_ item: MealItemData, food: FoodItem?, aiRecord: AIEstimationRecord?) -> MealItem {
        MealItem(
            id: item.id,
            order: item.order,
            foodItem: food,
            adHocName: item.adHocName,
            quantityGrams: item.quantityGrams,
            kcal: item.nutrition.kcal,
            proteinG: item.nutrition.proteinG,
            carbsG: item.nutrition.carbsG,
            fatG: item.nutrition.fatG,
            fiberG: item.nutrition.fiberG,
            provenance: item.provenance,
            aiRecord: aiRecord,
            confidence: item.confidence
        )
    }

    private func makePhoto(_ photo: PhotoAttachmentData) -> PhotoAttachment {
        PhotoAttachment(id: photo.id, relativePath: photo.relativePath, capturedAt: photo.capturedAt, kind: photo.kind)
    }
}

/// Models keyed by a UUID `id`, so one lookup helper serves them all.
protocol IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<Self>
}

extension FoodItem: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<FoodItem> { #Predicate { $0.id == id } }
}

extension Recipe: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<Recipe> { #Predicate { $0.id == id } }
}

extension RecipeComponent: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<RecipeComponent> { #Predicate { $0.id == id } }
}

extension MealEntry: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<MealEntry> { #Predicate { $0.id == id } }
}

extension MealItem: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<MealItem> { #Predicate { $0.id == id } }
}

extension AIEstimationRecord: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<AIEstimationRecord> { #Predicate { $0.id == id } }
}

extension PhotoAttachment: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<PhotoAttachment> { #Predicate { $0.id == id } }
}

extension ShotEvent: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<ShotEvent> { #Predicate { $0.id == id } }
}

extension MedicationProfile: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<MedicationProfile> { #Predicate { $0.id == id } }
}

extension SideEffectEntry: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<SideEffectEntry> { #Predicate { $0.id == id } }
}

extension PlannedShot: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<PlannedShot> { #Predicate { $0.id == id } }
}

extension PlannedMeal: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<PlannedMeal> { #Predicate { $0.id == id } }
}

extension JournalEntry: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<JournalEntry> { #Predicate { $0.id == id } }
}

extension SwiftDataStore {
    /// Test seam: the number of stored rows of one model type.
    func rowCount<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }
}
