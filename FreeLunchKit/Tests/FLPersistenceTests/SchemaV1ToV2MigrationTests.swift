// SPDX-License-Identifier: GPL-3.0-or-later
// V1 → V2 migration, proven on disk: a store written through the frozen
// FreeLunchSchemaV1 types, with every V1 entity and every relationship
// populated, opens under V2 through the production path
// (`SwiftDataStore(kind:at:)` → FreeLunchContainer → FreeLunchMigrationPlan)
// with nothing lost. Every value is synthetic.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

private typealias V1 = FreeLunchSchemaV1

/// The plan a V1 build shipped with: V1 alone, no stages.
private enum ShippedV1MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [FreeLunchSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

@MainActor
@Suite("Schema V1 → V2 migration on a seeded V1 store")
struct SchemaV1ToV2MigrationTests {
    /// Rows the fixture writes, per V1 entity.
    let expectedCounts: [String: Int] = [
        "FoodItem": 2, "Recipe": 1, "RecipeComponent": 1, "MealEntry": 1,
        "MealItem": 2, "AIEstimationRecord": 1, "PhotoAttachment": 2,
        "ShotEvent": 1, "MedicationProfile": 1, "SideEffectEntry": 1,
        "WeightSampleMirror": 1, "Correction": 1, "PlannedShot": 1,
        "PlannedMeal": 1, "JournalEntry": 1, "FormulaVersion": 1,
        "TargetPeriod": 1, "RecentFoodSnapshot": 1, "WatchOutboxRecord": 1
    ]

    @Test("the fixture covers every V1 entity")
    func fixtureCoversV1() {
        let v1Entities = Set(FreeLunchSchemaV1.models.map { String(describing: $0) })
        #expect(Set(expectedCounts.keys) == v1Entities)
        #expect(expectedCounts.values.allSatisfy { $0 > 0 })
    }

    @Test("a V1 store opens under V2 with every row, value and relationship", arguments: FreeLunchStoreKind.allCases)
    func v1StoreOpensUnderV2(kind: FreeLunchStoreKind) throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        try writeV1Store(kind: kind, at: url)

        let store = try SwiftDataStore(kind: kind, at: .file(url))
        #expect(try migratedCounts(store) == expectedCounts)
        #expect(try store.rowCount(DietarySampleMirror.self) == 0)
        try expectSpotValues(store)
    }

    @Test("the migrated phone store reads through the public API and takes V2 rows")
    func migratedPhoneStoreIsLive() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        try writeV1Store(kind: .phone, at: url)

        let dietary = DietarySampleData(
            hkUUID: uid(81_001),
            date: at(day: 5, hour: 4),
            energy: Kilocalories(410),
            protein: Grams(22),
            sourceBundleID: "com.example.synthetic.diary"
        )
        do {
            let store = try SwiftDataStore.phone(at: .file(url))
            let food = try #require(try store.food(id: uid(80_001)))
            #expect(food.name == "Synthetic oats")
            #expect(food.servings == [ServingDef(name: "cup", grams: Grams(80))])
            let meal = try #require(try store.meal(id: uid(80_020)))
            #expect(meal.items.map(\.foodID) == [uid(80_001), nil])
            #expect(meal.items.map(\.aiRecordID) == [uid(80_040), nil])
            #expect(meal.photos.map(\.id) == [uid(80_030)])
            #expect(try store.weightSamples(includingDeletedInHK: true).map(\.hkUUID) == [uid(80_080)])
            #expect(try store.corrections(targetKind: nil).map(\.id) == [uid(80_081)])
            #expect(try store.targetLedger().periods.map(\.id) == [uid(80_101)])
            try store.upsertDietarySample(dietary)
        }

        // A second open is V2 → V2: no stage runs and both lanes survive.
        let reopened = try SwiftDataStore.phone(at: .file(url))
        #expect(try migratedCounts(reopened) == expectedCounts)
        #expect(
            try reopened.dietarySamples(from: at(day: 5), through: at(day: 5), calendar: utcCalendar) == [dietary]
        )
    }

    // MARK: - Fixture

    /// Writes one row graph through V1 types into a V1-only container, the
    /// way a shipped V1 build left the file.
    private func writeV1Store(kind: FreeLunchStoreKind, at url: URL) throws {
        let schema = Schema(versionedSchema: FreeLunchSchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ShippedV1MigrationPlan.self,
            configurations: ModelConfiguration(kind.storeName, schema: schema, url: url)
        )
        let context = ModelContext(container)

        let oats = V1.FoodItem(
            id: uid(80_001), name: "Synthetic oats", brand: "Example Mill",
            kcal: 380, proteinG: 13, carbsG: 67, fatG: 7, fiberG: 10, isLiquid: false,
            servingsJSON: try ServingsCoding.encode([ServingDef(name: "cup", grams: Grams(80))]),
            origin: .custom, useCount: 4, lastUsedAt: at(hour: 1), lastPortionGrams: 60, archivedAt: nil
        )
        let retired = V1.FoodItem(
            id: uid(80_002), name: "Synthetic retired bar", brand: nil,
            kcal: 450, proteinG: 20, carbsG: 50, fatG: 18, fiberG: nil, isLiquid: false,
            servingsJSON: try ServingsCoding.encode([]),
            origin: .seeded, useCount: 0, lastUsedAt: nil, lastPortionGrams: nil, archivedAt: at(day: -1)
        )
        let recipe = V1.Recipe(id: uid(80_010), name: "Synthetic porridge", yieldGrams: 450)
        let component = V1.RecipeComponent(id: uid(80_011), order: 0, grams: 80, foodItem: oats)
        component.recipe = recipe

        let meal = V1.MealEntry(
            id: uid(80_020), state: .logged, createdAt: at(), loggedAt: at(hour: 1),
            hunger: 3, note: "synthetic breakfast", source: .phone
        )
        let mealPhoto = V1.PhotoAttachment(
            id: uid(80_030), relativePath: "photos/synthetic-meal.heic", capturedAt: at(), kind: .meal
        )
        mealPhoto.meal = meal
        let estimate = V1.AIEstimationRecord(
            id: uid(80_040), createdAt: at(hour: 0.5), photo: mealPhoto, hint: "bowl",
            providerTier: 1, modelID: "synthetic-model", status: .complete,
            responseJSON: Data(#"{"items":1}"#.utf8), userCorrections: ["less oats"]
        )
        let oatsItem = V1.MealItem(
            id: uid(80_021), order: 0, foodItem: oats, adHocName: nil, quantityGrams: 60,
            kcal: 228, proteinG: 7.8, carbsG: 40.2, fatG: 4.2, fiberG: 6,
            provenance: .aiEstimate, aiRecord: estimate, confidence: 0.8
        )
        oatsItem.meal = meal
        let coffeeItem = V1.MealItem(
            id: uid(80_022), order: 1, foodItem: nil, adHocName: "Synthetic coffee", quantityGrams: 250,
            kcal: 5, proteinG: 0.3, carbsG: 0, fatG: 0, fiberG: nil,
            provenance: .typed, aiRecord: nil, confidence: nil
        )
        coffeeItem.meal = meal

        let journal = V1.JournalEntry(id: uid(80_050), at: at(day: 1), text: "Synthetic journal note")
        let labelPhoto = V1.PhotoAttachment(
            id: uid(80_031), relativePath: "photos/synthetic-label.heic", capturedAt: at(day: 1), kind: .label
        )
        labelPhoto.journalEntry = journal

        let medication = V1.MedicationProfile(
            id: uid(80_060), name: "Synthetic GLP-1", halfLifeHours: 168, tmaxHours: 48,
            intervalDays: 7, archivedAt: nil
        )
        let shot = V1.ShotEvent(
            id: uid(80_061), takenAt: at(day: 2), doseMg: 2.5, medication: medication,
            siteRaw: InjectionSite.abdomenLeft.rawValue, note: "synthetic", source: .phone
        )
        let sideEffect = V1.SideEffectEntry(
            id: uid(80_070), occurredAt: at(day: 2, hour: 6), typeKind: "nausea",
            otherText: nil, severity: 2, note: nil
        )

        let weight = V1.WeightSampleMirror(
            hkUUID: uid(80_080), measuredAt: at(day: 3), weightKg: 82.5,
            sourceBundleID: "com.example.synthetic.scale", deletedInHK: false
        )
        let correction = V1.Correction(
            id: uid(80_081), createdAt: at(day: 3, hour: 1), targetKind: .hkWeightSample,
            targetID: uid(80_080).uuidString, action: .exclude, replacement: nil, reason: "synthetic"
        )

        let plannedShot = V1.PlannedShot(
            id: uid(80_090), plannedAt: at(day: 2), notificationID: "synthetic-shot",
            status: .done, fulfilledBy: uid(80_061), doseMg: 2.5
        )
        let plannedMeal = V1.PlannedMeal(
            id: uid(80_091), plannedAt: at(day: 1, hour: 4), notificationID: nil,
            status: .pending, fulfilledBy: nil, name: "Synthetic lunch", note: "plan"
        )

        let builtin = StoredFormulaVersion.builtinV1(id: uid(80_100), createdAt: at())
        let origin = FormulaOriginCoding.kind(of: FormulaOrigin(builtin.formula.origin))
        let formula = V1.FormulaVersion(
            id: uid(80_100), name: builtin.formula.name, definition: builtin.definition,
            createdAt: at(), originKind: origin.kind, builtinID: origin.builtinID,
            paramsJSON: try FormulaParamsCoding.encode(builtin.formula.parameters)
        )
        let period = V1.TargetPeriod(
            id: uid(80_101), startDate: at(day: 4), endDate: nil,
            expenditureAtAdoptionKcal: 2_300, calculatedTargetKcal: 1_800, adoptedTargetKcal: 1_750,
            proteinTargetG: 128, fatFloorPct: 25, formulaVersion: formula
        )

        let snapshot = V1.RecentFoodSnapshot(foodID: uid(80_001), name: "Synthetic oats", lastPortionGrams: 60, rank: 0)
        let outbox = V1.WatchOutboxRecord(
            id: uid(80_110), kind: .meal, subjectID: uid(80_020), queuedAt: at(hour: 2), payload: Data([1, 2, 3])
        )

        let rows: [any PersistentModel] = [
            oats, retired, recipe, component, meal, mealPhoto, estimate, oatsItem, coffeeItem,
            journal, labelPhoto, medication, shot, sideEffect, weight, correction,
            plannedShot, plannedMeal, formula, period, snapshot, outbox
        ]
        for row in rows { context.insert(row) }
        try context.save()

        // The file really holds V1 rows before V2 ever opens it.
        #expect(try context.fetchCount(FetchDescriptor<V1.FoodItem>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<V1.MealItem>()) == 2)
        #expect(try context.fetch(FetchDescriptor<V1.RecipeComponent>()).first?.recipe?.id == uid(80_010))
    }

    // MARK: - Reads under V2

    private func migratedCounts(_ store: SwiftDataStore) throws -> [String: Int] {
        [
            "FoodItem": try store.rowCount(FoodItem.self),
            "Recipe": try store.rowCount(Recipe.self),
            "RecipeComponent": try store.rowCount(RecipeComponent.self),
            "MealEntry": try store.rowCount(MealEntry.self),
            "MealItem": try store.rowCount(MealItem.self),
            "AIEstimationRecord": try store.rowCount(AIEstimationRecord.self),
            "PhotoAttachment": try store.rowCount(PhotoAttachment.self),
            "ShotEvent": try store.rowCount(ShotEvent.self),
            "MedicationProfile": try store.rowCount(MedicationProfile.self),
            "SideEffectEntry": try store.rowCount(SideEffectEntry.self),
            "WeightSampleMirror": try store.rowCount(WeightSampleMirror.self),
            "Correction": try store.rowCount(Correction.self),
            "PlannedShot": try store.rowCount(PlannedShot.self),
            "PlannedMeal": try store.rowCount(PlannedMeal.self),
            "JournalEntry": try store.rowCount(JournalEntry.self),
            "FormulaVersion": try store.rowCount(FormulaVersion.self),
            "TargetPeriod": try store.rowCount(TargetPeriod.self),
            "RecentFoodSnapshot": try store.rowCount(RecentFoodSnapshot.self),
            "WatchOutboxRecord": try store.rowCount(WatchOutboxRecord.self)
        ]
    }

    private func all<T: PersistentModel>(_ type: T.Type, in store: SwiftDataStore) throws -> [T] {
        try store.context.fetch(FetchDescriptor<T>())
    }

    /// One distinctive value per entity, plus every relationship, read as
    /// V2 models (store-kind agnostic, so watch-only and phone-only entities
    /// are checked in both store files).
    private func expectSpotValues(_ store: SwiftDataStore) throws {
        let oats = try #require(try store.model(FoodItem.self, id: uid(80_001)))
        #expect(oats.brand == "Example Mill")
        #expect(oats.kcal == 380 && oats.fiberG == 10 && oats.useCount == 4 && oats.lastPortionGrams == 60)
        #expect(try ServingsCoding.decode(oats.servingsJSON) == [ServingDef(name: "cup", grams: Grams(80))])
        #expect(Set(oats.mealItems.map(\.id)) == [uid(80_021)])
        #expect(oats.recipeComponents.map(\.id) == [uid(80_011)])
        let retired = try #require(try store.model(FoodItem.self, id: uid(80_002)))
        #expect(retired.archivedAt == at(day: -1) && retired.origin == .seeded && retired.fiberG == nil)

        let recipe = try #require(try store.model(Recipe.self, id: uid(80_010)))
        #expect(recipe.yieldGrams == 450)
        #expect(recipe.components.map(\.id) == [uid(80_011)])
        let component = try #require(try store.model(RecipeComponent.self, id: uid(80_011)))
        #expect(component.grams == 80 && component.foodItem?.id == uid(80_001) && component.recipe?.id == uid(80_010))

        let meal = try #require(try store.model(MealEntry.self, id: uid(80_020)))
        #expect(meal.state == .logged && meal.loggedAt == at(hour: 1) && meal.hunger == 3)
        #expect(meal.note == "synthetic breakfast" && meal.source == .phone)
        #expect(Set(meal.items.map(\.id)) == [uid(80_021), uid(80_022)])
        #expect(meal.photos.map(\.id) == [uid(80_030)])

        let oatsItem = try #require(try store.model(MealItem.self, id: uid(80_021)))
        #expect(oatsItem.kcal == 228 && oatsItem.proteinG == 7.8 && oatsItem.fiberG == 6 && oatsItem.confidence == 0.8)
        #expect(oatsItem.provenance == .aiEstimate)
        #expect(oatsItem.foodItem?.id == uid(80_001) && oatsItem.aiRecord?.id == uid(80_040) && oatsItem.meal?.id == uid(80_020))
        let coffeeItem = try #require(try store.model(MealItem.self, id: uid(80_022)))
        #expect(coffeeItem.adHocName == "Synthetic coffee" && coffeeItem.foodItem == nil && coffeeItem.aiRecord == nil)

        let estimate = try #require(try store.model(AIEstimationRecord.self, id: uid(80_040)))
        #expect(estimate.status == .complete && estimate.modelID == "synthetic-model" && estimate.providerTier == 1)
        #expect(estimate.responseJSON == Data(#"{"items":1}"#.utf8) && estimate.userCorrections == ["less oats"])
        #expect(estimate.photo?.id == uid(80_030) && estimate.items.map(\.id) == [uid(80_021)])

        let mealPhoto = try #require(try store.model(PhotoAttachment.self, id: uid(80_030)))
        #expect(mealPhoto.relativePath == "photos/synthetic-meal.heic" && mealPhoto.kind == .meal)
        #expect(mealPhoto.meal?.id == uid(80_020) && mealPhoto.journalEntry == nil)
        #expect(mealPhoto.aiRecords.map(\.id) == [uid(80_040)])
        let labelPhoto = try #require(try store.model(PhotoAttachment.self, id: uid(80_031)))
        #expect(labelPhoto.kind == .label && labelPhoto.journalEntry?.id == uid(80_050) && labelPhoto.meal == nil)

        let journal = try #require(try store.model(JournalEntry.self, id: uid(80_050)))
        #expect(journal.text == "Synthetic journal note" && journal.photos.map(\.id) == [uid(80_031)])

        let medication = try #require(try store.model(MedicationProfile.self, id: uid(80_060)))
        #expect(medication.name == "Synthetic GLP-1" && medication.halfLifeHours == 168 && medication.intervalDays == 7)
        #expect(medication.shots.map(\.id) == [uid(80_061)])
        let shot = try #require(try store.model(ShotEvent.self, id: uid(80_061)))
        #expect(shot.doseMg == 2.5 && shot.siteRaw == "abdomenLeft" && shot.source == .phone)
        #expect(shot.medication?.id == uid(80_060))

        let sideEffect = try #require(try store.model(SideEffectEntry.self, id: uid(80_070)))
        #expect(sideEffect.typeKind == "nausea" && sideEffect.severity == 2 && sideEffect.occurredAt == at(day: 2, hour: 6))

        let weight = try #require(try all(WeightSampleMirror.self, in: store).first)
        #expect(weight.hkUUID == uid(80_080) && weight.weightKg == 82.5 && weight.deletedInHK == false)
        #expect(weight.sourceBundleID == "com.example.synthetic.scale")
        let correction = try #require(try store.model(Correction.self, id: uid(80_081)))
        #expect(correction.targetKind == .hkWeightSample && correction.action == .exclude)
        #expect(correction.targetID == uid(80_080).uuidString && correction.reason == "synthetic")

        let plannedShot = try #require(try store.model(PlannedShot.self, id: uid(80_090)))
        #expect(plannedShot.status == .done && plannedShot.fulfilledBy == uid(80_061) && plannedShot.doseMg == 2.5)
        #expect(plannedShot.notificationID == "synthetic-shot")
        let plannedMeal = try #require(try store.model(PlannedMeal.self, id: uid(80_091)))
        #expect(plannedMeal.name == "Synthetic lunch" && plannedMeal.status == .pending && plannedMeal.note == "plan")

        let builtin = StoredFormulaVersion.builtinV1(id: uid(80_100), createdAt: at())
        let formula = try #require(try all(FormulaVersion.self, in: store).first)
        #expect(formula.id == uid(80_100) && formula.definition == builtin.definition)
        #expect(try formula.asStoredFormulaVersion() == builtin)
        #expect(formula.periods.map(\.id) == [uid(80_101)])
        let period = try #require(try all(TargetPeriod.self, in: store).first)
        #expect(period.id == uid(80_101) && period.startDate == at(day: 4) && period.endDate == nil)
        #expect(period.expenditureAtAdoptionKcal == 2_300 && period.calculatedTargetKcal == 1_800)
        #expect(period.adoptedTargetKcal == 1_750 && period.proteinTargetG == 128 && period.fatFloorPct == 25)
        #expect(period.formulaVersion?.id == uid(80_100))

        let snapshot = try #require(try all(RecentFoodSnapshot.self, in: store).first)
        #expect(snapshot.foodID == uid(80_001) && snapshot.name == "Synthetic oats")
        #expect(snapshot.lastPortionGrams == 60 && snapshot.rank == 0)
        let outbox = try #require(try all(WatchOutboxRecord.self, in: store).first)
        #expect(outbox.id == uid(80_110) && outbox.kind == .meal && outbox.subjectID == uid(80_020))
        #expect(outbox.queuedAt == at(hour: 2) && outbox.payload == Data([1, 2, 3]))
    }
}
