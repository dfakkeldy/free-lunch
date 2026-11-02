// SPDX-License-Identifier: GPL-3.0-or-later
// Predicate, store-shape, and corrupted-ledger regressions. All fixtures are synthetic.
import FLCore
import FLEnergyCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

@MainActor
@Suite("Persistence hardening")
struct StoreHardeningTests {
    @Test("weight upserts retain the latest deterministic mirror for every HealthKit UUID")
    func weightUpsertsUseKeyedMirrorLookup() throws {
        let store = try makeInMemoryStore()
        let total = 3_000
        var expected: [UUID: WeightSampleData] = [:]

        for index in 1...total {
            // Every seventh index repeats the immediately preceding UUID.
            let hkUUID = deterministicHKUUID(index.isMultiple(of: 7) ? index - 1 : index)
            let sample = WeightSampleData(
                hkUUID: hkUUID,
                measuredAt: at(day: Double(index)),
                weight: Kilograms(70 + Double(index) / 1_000),
                sourceBundleID: "com.example.synthetic.scale"
            )
            try store.upsertWeightSample(sample)
            expected[hkUUID] = sample
        }

        // 3,000 inputs less 428 seventh-index repeats.
        #expect(expected.count == 2_572)
        #expect(try store.rowCount(WeightSampleMirror.self) == 2_572)
        let stored = try store.weightSamples(includingDeletedInHK: true)
        #expect(stored.count == 2_572)
        for sample in stored {
            #expect(sample == expected[sample.hkUUID])
        }

        let deleted = [deterministicHKUUID(6), deterministicHKUUID(13), deterministicHKUUID(2_999)]
        for hkUUID in deleted {
            try store.markWeightSampleDeletedInHK(hkUUID: hkUUID)
        }
        let afterDeletion = try store.weightSamples(includingDeletedInHK: true)
        #expect(afterDeletion.filter(\.deletedInHK).map(\.hkUUID).sorted { $0.uuidString < $1.uuidString }
            == deleted.sorted { $0.uuidString < $1.uuidString })
        #expect(try store.weightSamples(includingDeletedInHK: false).count == 2_569)
    }

    @Test("store kind blocks the opposite store surface while a test-built store remains unrestricted")
    func storeKindGuards() throws {
        let phone = try SwiftDataStore.phone(at: .inMemory)
        let digest = [RecentFoodSnapshotData(foodID: uid(70_001), name: "Synthetic", lastPortionGrams: 40)]
        let shot = ShotEventData(
            id: uid(70_002), takenAt: at(), dose: Milligrams(2.5),
            medicationID: uid(70_003), source: .watch
        )
        let hunger = WatchHungerEdit(mealID: uid(70_004), hunger: 3, editedAt: at())
        let formula = StoredFormulaVersion.builtinV1(id: uid(70_008), createdAt: at())
        let weight = WeightSampleData(
            hkUUID: uid(70_009), measuredAt: at(), weight: Kilograms(70),
            sourceBundleID: "com.example.synthetic.scale"
        )
        let correction = CorrectionData(
            id: uid(70_010), createdAt: at(), targetKind: .hkWeightSample,
            targetID: uid(70_009).uuidString, action: .exclude
        )
        let estimation = AIEstimationRecordData(
            id: uid(70_011), createdAt: at(), providerTier: 1, modelID: "synthetic"
        )

        #expect(throws: FreeLunchStoreError.watchOnlyOperation("replaceRecentFoods")) { try phone.replaceRecentFoods(digest) }
        #expect(throws: FreeLunchStoreError.watchOnlyOperation("recentFoods")) { try phone.recentFoods() }
        #expect(throws: FreeLunchStoreError.watchOnlyOperation("enqueueShot")) { try phone.enqueueShot(shot, queuedAt: at()) }
        #expect(throws: FreeLunchStoreError.watchOnlyOperation("enqueueMeal")) { try phone.enqueueMeal(id: uid(70_005), payload: Data(), queuedAt: at()) }
        #expect(throws: FreeLunchStoreError.watchOnlyOperation("enqueueHungerEdit")) { try phone.enqueueHungerEdit(hunger) }
        #expect(throws: FreeLunchStoreError.watchOnlyOperation("outbox")) { try phone.outbox() }
        #expect(throws: FreeLunchStoreError.watchOnlyOperation("acknowledge")) { try phone.acknowledge([]) }

        let watch = try SwiftDataStore.watch(at: .inMemory)
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("weightSamples")) { try watch.weightSamples(includingDeletedInHK: true) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("adoptTarget")) {
            try watch.adoptTarget(
                TargetAdoption(
                    calculated: CalculatedTarget(expenditureKcal: 2_000, rateGoal: .maintenance),
                    adoptedTargetKcal: 1_200,
                    macros: MacroTargets(proteinTargetG: 128, fatFloorPct: 20)!,
                    formula: .builtinV1
                ),
                on: at(), calendar: utcCalendar, id: uid(70_012)
            )
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("registerFormulaVersion")) { try watch.registerFormulaVersion(formula) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("upsertWeightSample")) { try watch.upsertWeightSample(weight) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("markWeightSampleDeletedInHK")) { try watch.markWeightSampleDeletedInHK(hkUUID: uid(70_009)) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("addCorrection")) { try watch.addCorrection(correction) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("deleteCorrection")) { try watch.deleteCorrection(id: uid(70_010)) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("corrections")) { try watch.corrections(targetKind: nil) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("correctedWeightView")) { try watch.correctedWeightView() }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("saveAICapture")) { try watch.saveAICapture(AICaptureSnapshot(photos: [], records: [], items: []), toMeal: uid(70_013)) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("aiCapture")) { try watch.aiCapture(forMeal: uid(70_013)) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("setLoggedAt")) { try watch.setLoggedAt(at(), mealID: uid(70_013)) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("setItemQuantity")) { try watch.setItemQuantity(Grams(1), itemID: uid(70_014)) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("updateAIEstimation")) { try watch.updateAIEstimation(estimation) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("formulaVersion")) { try watch.formulaVersion(id: uid(70_008)) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("targetLedger")) { try watch.targetLedger() }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("formulaVersions")) { try watch.formulaVersions() }

        let unrestricted = SwiftDataStore(container: try FreeLunchContainer.make(.phone, at: .inMemory))
        try unrestricted.replaceRecentFoods(digest)
        try unrestricted.createFood(FoodItemData(id: uid(70_007), name: "Also synthetic", per100g: nutrition(100, 5, 10, 2), origin: .custom))
        #expect(try unrestricted.recentFoods() == digest)
        #expect(try unrestricted.food(id: uid(70_007))?.name == "Also synthetic")
    }

    @Test("target ledger refuses corrupt target period rows", arguments: 0..<4)
    func targetLedgerRejectsCorruptRows(variant: Int) throws {
        let store = try makeInMemoryStore()
        let formula = try storedFormulaRow(in: store)

        switch variant {
        case 0:
            insertPeriod(store, id: uid(71_001), start: 10, end: nil, formula: formula)
            insertPeriod(store, id: uid(71_002), start: 11, end: nil, formula: formula)
        case 1:
            insertPeriod(store, id: uid(71_003), start: 10, end: 15, formula: formula)
            insertPeriod(store, id: uid(71_004), start: 14, end: nil, formula: formula)
        case 2:
            insertPeriod(store, id: uid(71_005), start: 10, end: 8, formula: formula)
        default:
            insertPeriod(store, id: uid(71_006), start: 10, end: nil, adopted: 0, formula: formula)
        }
        try store.context.save()

        let expectedID: UUID = switch variant {
        case 0: uid(71_001)
        case 1: uid(71_004)
        case 2: uid(71_005)
        default: uid(71_006)
        }
        #expect(throws: TargetStoreError.invalidTargetPeriod(expectedID)) { try store.targetLedger() }
    }

    @Test("target ledger loads finite non-positive calculated targets and permits re-adoption")
    func targetLedgerLoadsFiniteNonPositiveCalculatedTarget() throws {
        let store = try makeInMemoryStore()
        let formula = try storedFormulaRow(in: store)
        insertPeriod(
            store, id: uid(71_101), start: 10, end: nil,
            expenditure: 2_000, calculated: -200, adopted: 1_200, formula: formula
        )
        try store.context.save()

        let ledger = try store.targetLedger()
        let period = try #require(ledger.periods.first)
        #expect(period.expenditureAtAdoptionKcal == 2_000)
        #expect(period.calculatedTargetKcal == -200)
        #expect(period.adoptedTargetKcal == 1_200)

        let outcome = try store.adoptTarget(
            TargetAdoption(
                calculated: CalculatedTarget(expenditureKcal: 2_000, rateGoal: .maintenance),
                adoptedTargetKcal: 1_200,
                macros: MacroTargets(proteinTargetG: 128, fatFloorPct: 20)!,
                formula: .builtinV1
            ),
            on: at(day: 11), calendar: utcCalendar, id: uid(71_102)
        )
        #expect(outcome.ledger.periods.map(\.id) == [uid(71_101), uid(71_102)])
    }

    @Test("target ledger rejects infinite expenditure", arguments: [Double.infinity, -Double.infinity])
    func targetLedgerRejectsInfiniteExpenditure(expenditure: Double) throws {
        let store = try makeInMemoryStore()
        let formula = try storedFormulaRow(in: store)
        insertPeriod(store, id: uid(71_103), start: 10, end: nil, expenditure: expenditure, formula: formula)
        try store.context.save()

        #expect(throws: TargetStoreError.invalidTargetPeriod(uid(71_103))) { try store.targetLedger() }
    }

    @Test("valid target ledger still loads after stored-row validation")
    func validTargetLedgerLoads() throws {
        let store = try makeInMemoryStore()
        let formula = try storedFormulaRow(in: store)
        insertPeriod(store, id: uid(71_101), start: 10, end: 14, formula: formula)
        insertPeriod(store, id: uid(71_102), start: 15, end: nil, formula: formula)
        try store.context.save()

        #expect(try store.targetLedger().periods.map(\.id) == [uid(71_101), uid(71_102)])
    }

    @Test("AI capture lookup stays scoped to its meal")
    func aiCaptureLookupIsMealScoped() throws {
        let store = try makeInMemoryStore()
        let firstMeal = uid(72_001)
        let secondMeal = uid(72_002)
        try store.createMeal(MealEntryData(id: firstMeal, createdAt: at(), source: .phone))
        try store.createMeal(MealEntryData(id: secondMeal, createdAt: at(hour: 1), source: .phone))
        try store.saveAICapture(capture(photo: uid(72_003), record: uid(72_004), item: uid(72_005)), toMeal: firstMeal)
        try store.saveAICapture(capture(photo: uid(72_006), record: uid(72_007), item: uid(72_008)), toMeal: secondMeal)

        let loaded = try store.aiCapture(forMeal: firstMeal)
        #expect(loaded.photos.map(\.id) == [uid(72_003)])
        #expect(loaded.records.map(\.id) == [uid(72_004)])
        #expect(loaded.items.map(\.id) == [uid(72_005)])
    }

    private func deterministicHKUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private func storedFormulaRow(in store: SwiftDataStore) throws -> FormulaVersion {
        let stored = StoredFormulaVersion.builtinV1(id: uid(71_000), createdAt: at())
        try store.registerFormulaVersion(stored)
        return try #require(try store.context.fetch(FetchDescriptor<FormulaVersion>()).first { $0.id == stored.id })
    }

    private func insertPeriod(
        _ store: SwiftDataStore,
        id: UUID,
        start: Double,
        end: Double?,
        expenditure: Double = 2_400,
        calculated: Double = 1_900,
        adopted: Double = 1_900,
        formula: FormulaVersion
    ) {
        store.context.insert(TargetPeriod(
            id: id,
            startDate: at(day: start),
            endDate: end.map { at(day: $0) },
            expenditureAtAdoptionKcal: expenditure,
            calculatedTargetKcal: calculated,
            adoptedTargetKcal: adopted,
            proteinTargetG: 128,
            fatFloorPct: 20,
            formulaVersion: formula
        ))
    }

    private func capture(photo: UUID, record: UUID, item: UUID) -> AICaptureSnapshot {
        AICaptureSnapshot(
            photos: [PhotoAttachmentData(id: photo, relativePath: "synthetic-\(photo.uuidString).jpg", capturedAt: at(), kind: .meal)],
            records: [AIEstimationRecordData(id: record, createdAt: at(), photoID: photo, providerTier: 1, modelID: "synthetic", status: .complete)],
            items: [MealItemData(
                id: item,
                order: 0,
                foodID: nil,
                adHocName: "Synthetic capture",
                quantity: Grams(100),
                nutrition: nutrition(200, 10, 20, 5),
                provenance: .aiEstimate,
                aiRecordID: record,
                confidence: 0.8
            )]
        )
    }
}
