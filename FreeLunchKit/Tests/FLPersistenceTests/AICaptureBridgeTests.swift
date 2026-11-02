// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation
import Testing
@testable import FLPersistence

@MainActor
@Suite("AI capture persistence bridge")
struct AICaptureBridgeTests {
    @Test("cold-load keeps meal, failed, and label captures while excluding manual items")
    func coldLoadRoundTrip() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let mealID = uid(810)
        let mealPhotoID = uid(811)
        let mealRecordID = uid(812)
        let failedPhotoID = uid(813)
        let failedRecordID = uid(814)
        let labelPhotoID = uid(815)
        let labelRecordID = uid(816)
        let response = Data("{\"items\":[{\"name\":\"Rice\",\"estPortionGrams\":150,\"kcal\":300,\"protein\":12,\"carbs\":30,\"fat\":10,\"confidence\":0.8}],\"note\":\"synthetic\"}".utf8)

        do {
            let writer = try SwiftDataStore.phone(at: .file(url))
            try createDraft(writer, id: mealID)
            try writer.saveAICapture(AICaptureSnapshot(
                photos: [
                    PhotoAttachmentData(id: mealPhotoID, relativePath: "meal.jpg", capturedAt: at(hour: 1), kind: .meal),
                    PhotoAttachmentData(id: failedPhotoID, relativePath: "failed.jpg", capturedAt: at(hour: 2), kind: .meal),
                    PhotoAttachmentData(id: labelPhotoID, relativePath: "label.jpg", capturedAt: at(hour: 3), kind: .label)
                ],
                records: [
                    AIEstimationRecordData(id: mealRecordID, createdAt: at(hour: 1), photoID: mealPhotoID, hint: "dinner", providerTier: 2, modelID: "meal-v2", status: .complete, responseJSON: response, userCorrections: ["less oil"]),
                    AIEstimationRecordData(id: failedRecordID, createdAt: at(hour: 2), photoID: failedPhotoID, hint: nil, providerTier: 1, modelID: "meal-v1", status: .failed, responseJSON: Data("bad".utf8), userCorrections: []),
                    AIEstimationRecordData(id: labelRecordID, createdAt: at(hour: 3), photoID: labelPhotoID, hint: "per serving", providerTier: 3, modelID: "label-v1", status: .complete, responseJSON: nil, userCorrections: [])
                ],
                items: [
                    aiItem(id: uid(817), recordID: mealRecordID, name: "Rice", grams: 150, values: nutrition(300, 12, 30, 10), provenance: .aiEstimate, confidence: 0.8),
                    aiItem(id: uid(818), recordID: mealRecordID, name: "Beans", grams: 85, values: nutrition(110, 7, 20, 0.4), provenance: .aiEstimate, confidence: 0.55),
                    aiItem(id: uid(819), recordID: labelRecordID, name: "Label oats", grams: 40, values: nutrition(160, 8, 16, 6), provenance: .labelOCR, confidence: nil)
                ]
            ), toMeal: mealID)
            _ = try writer.addItem(MealItemInput(
                id: uid(820), kind: .adHoc(name: "Manual toast", nutrition: nutrition(90, 3, 15, 1)),
                quantity: Grams(30), provenance: .typed
            ), toMeal: mealID)
        }

        let reader = try SwiftDataStore.phone(at: .file(url))
        let loaded = try reader.aiCapture(forMeal: mealID)
        #expect(loaded.photos.map(\.id) == [mealPhotoID, failedPhotoID, labelPhotoID])
        #expect(loaded.photos.map(\.kind) == [.meal, .meal, .label])
        #expect(loaded.records.map(\.id) == [mealRecordID, failedRecordID, labelRecordID])
        #expect(loaded.records[0].hint == "dinner")
        #expect(loaded.records[0].providerTier == 2)
        #expect(loaded.records[0].modelID == "meal-v2")
        #expect(loaded.records[0].responseJSON == response)
        #expect(loaded.records[0].userCorrections == ["less oil"])
        #expect(loaded.records[1].status == .failed)
        #expect(loaded.records[2].photoID == labelPhotoID)
        #expect(loaded.items.map(\.id) == [uid(817), uid(818), uid(819)])
        #expect(loaded.items.map(\.provenance) == [.aiEstimate, .aiEstimate, .labelOCR])
        #expect(loaded.items.map(\.confidence) == [0.8, 0.55, nil])
        #expect(loaded.items.map(\.aiRecordID) == [mealRecordID, mealRecordID, labelRecordID])
        #expect(try reader.meal(id: mealID)?.items.map(\.adHocName).contains("Manual toast") == true)
    }

    @Test("rerun updates AI items in place, appends new items, and removes dropped ones")
    func rerunReplacesInPlace() throws {
        let store = try makeInMemoryStore()
        let mealID = uid(830)
        let photoID = uid(831)
        let recordID = uid(832)
        let riceID = uid(833)
        let chickenID = uid(834)
        let droppedID = uid(835)
        let newID = uid(836)
        try createDraft(store, id: mealID)
        let initial = AICaptureSnapshot(
            photos: [PhotoAttachmentData(id: photoID, relativePath: "rerun.jpg", capturedAt: at(hour: 1), kind: .meal)],
            records: [AIEstimationRecordData(id: recordID, createdAt: at(hour: 1), photoID: photoID, hint: nil, providerTier: 1, modelID: "v1", status: .complete, responseJSON: Data("old".utf8), userCorrections: ["first"])],
            items: [
                aiItem(id: riceID, recordID: recordID, name: "rice", grams: 150, values: nutrition(300, 6, 66, 1), provenance: .aiEstimate, confidence: 0.8),
                aiItem(id: chickenID, recordID: recordID, name: "chicken", grams: 120, values: nutrition(250, 33, 0, 8), provenance: .aiEstimate, confidence: 0.7),
                aiItem(id: droppedID, recordID: recordID, name: "dropped", grams: 10, values: nutrition(10, 1, 1, 1), provenance: .aiEstimate, confidence: 0.1)
            ]
        )
        try store.saveAICapture(initial, toMeal: mealID)
        _ = try store.addItem(MealItemInput(
            id: uid(837), kind: .adHoc(name: "manual", nutrition: nutrition(50, 2, 8, 1)),
            quantity: Grams(25), provenance: .typed
        ), toMeal: mealID)
        let rerun = AICaptureSnapshot(
            photos: initial.photos,
            records: [AIEstimationRecordData(id: recordID, createdAt: at(hour: 1), photoID: photoID, hint: "more rice", providerTier: 2, modelID: "v2", status: .complete, responseJSON: Data("new".utf8), userCorrections: ["first", "second"])],
            items: [
                aiItem(id: riceID, recordID: recordID, name: "rice", grams: 200, values: nutrition(400, 8, 88, 2), provenance: .aiEstimate, confidence: 0.9),
                aiItem(id: chickenID, recordID: recordID, name: "chicken", grams: 120, values: nutrition(250, 33, 0, 8), provenance: .aiEstimate, confidence: 0.7),
                aiItem(id: newID, recordID: recordID, name: "broccoli", grams: 90, values: nutrition(30, 3, 6, 0), provenance: .aiEstimate, confidence: 0.6)
            ]
        )
        try store.saveAICapture(rerun, toMeal: mealID)

        let meal = try #require(try store.meal(id: mealID))
        let rice = try #require(meal.items.first { $0.id == riceID })
        let chicken = try #require(meal.items.first { $0.id == chickenID })
        let manual = try #require(meal.items.first { $0.id == uid(837) })
        let broccoli = try #require(meal.items.first { $0.id == newID })
        #expect(rice.order == 0 && rice.quantityGrams == 200 && sameBits(rice.nutrition, nutrition(400, 8, 88, 2)))
        #expect(chicken.order == 1 && chicken.quantityGrams == 120 && sameBits(chicken.nutrition, nutrition(250, 33, 0, 8)))
        #expect(manual.order == 3 && manual.adHocName == "manual")
        #expect(broccoli.order == 4 && broccoli.quantityGrams == 90)
        #expect(!meal.items.contains { $0.id == droppedID })
        #expect(meal.items.count == 4)
        #expect(try store.aiCapture(forMeal: mealID).records[0].userCorrections == ["first", "second"])
    }

    @Test("offline pending capture remains draft and later completes")
    func offlineThenCompletes() throws {
        let store = try makeInMemoryStore()
        let mealID = uid(840)
        let photoID = uid(841)
        let recordID = uid(842)
        try createDraft(store, id: mealID)
        let pending = AICaptureSnapshot(
            photos: [PhotoAttachmentData(id: photoID, relativePath: "offline.jpg", capturedAt: at(), kind: .meal)],
            records: [AIEstimationRecordData(id: recordID, createdAt: at(), photoID: photoID, providerTier: 1, modelID: "offline", status: .pending)],
            items: []
        )
        try store.saveAICapture(pending, toMeal: mealID)
        #expect(try store.aiCapture(forMeal: mealID).records[0].status == .pending)
        _ = try store.addItem(MealItemInput(
            id: uid(843), kind: .adHoc(name: "manual", nutrition: nutrition(10, 1, 1, 1)),
            quantity: Grams(10), provenance: .typed
        ), toMeal: mealID)
        #expect(try store.meal(id: mealID)?.state == .draft)
        #expect(try store.meal(id: mealID)?.items.map(\.id).contains(uid(843)) == true)

        try store.saveAICapture(AICaptureSnapshot(
            photos: pending.photos,
            records: [AIEstimationRecordData(id: recordID, createdAt: at(), photoID: photoID, providerTier: 1, modelID: "online", status: .complete, responseJSON: Data("done".utf8), userCorrections: [])],
            items: [aiItem(id: uid(844), recordID: recordID, name: "online", grams: 50, values: nutrition(80, 4, 8, 2), provenance: .aiEstimate, confidence: 0.5)]
        ), toMeal: mealID)
        #expect(try store.aiCapture(forMeal: mealID).records[0].status == .complete)
        #expect(try store.aiCapture(forMeal: mealID).items.map(\.id) == [uid(844)])
    }

    @Test("validation failure does not persist staged capture rows")
    func validationIsAtomic() throws {
        let store = try makeInMemoryStore()
        let mealID = uid(850)
        let photoID = uid(851)
        let recordID = uid(852)
        try createDraft(store, id: mealID)
        let invalid = AICaptureSnapshot(
            photos: [PhotoAttachmentData(id: photoID, relativePath: "atomic.jpg", capturedAt: at(), kind: .meal)],
            records: [AIEstimationRecordData(id: recordID, createdAt: at(), photoID: photoID, providerTier: 1, modelID: "m", status: .complete)],
            items: [
                aiItem(id: uid(853), recordID: recordID, name: "valid", grams: 20, values: nutrition(20, 1, 2, 1), provenance: .aiEstimate, confidence: 0.5),
                aiItem(id: uid(854), recordID: recordID, name: "invalid", grams: 0, values: nutrition(20, 1, 2, 1), provenance: .aiEstimate, confidence: 0.5)
            ]
        )
        #expect(throws: AICaptureBridgeError.invalidQuantity(uid(854))) {
            try store.saveAICapture(invalid, toMeal: mealID)
        }
        let afterFailure = try store.aiCapture(forMeal: mealID)
        #expect(afterFailure.photos.isEmpty && afterFailure.records.isEmpty && afterFailure.items.isEmpty)

        #expect(throws: AICaptureBridgeError.labelRecordNeedsPhoto(uid(855))) {
            try store.saveAICapture(AICaptureSnapshot(
                photos: [],
                records: [AIEstimationRecordData(id: uid(855), createdAt: at(), providerTier: 1, modelID: "label", status: .pending)],
                items: [aiItem(id: uid(857), recordID: uid(855), name: "label", grams: 10, values: nutrition(10, 1, 1, 1), provenance: .labelOCR, confidence: nil)]
            ), toMeal: mealID)
        }
        try createLoggedMeal(store, id: uid(856))
        #expect(throws: FreeLunchStoreError.mealNotDraft(uid(856))) {
            try store.saveAICapture(invalid, toMeal: uid(856))
        }
    }

    private func createDraft(_ store: SwiftDataStore, id: UUID) throws {
        try store.createMeal(MealEntryData(id: id, createdAt: at(), source: .phone))
    }

    private func createLoggedMeal(_ store: SwiftDataStore, id: UUID) throws {
        try store.createMeal(MealEntryData(id: id, state: .logged, createdAt: at(), loggedAt: at(), source: .phone))
    }

    private func aiItem(
        id: UUID,
        recordID: UUID,
        name: String,
        grams: Double,
        values: NutritionValues,
        provenance: ItemProvenance,
        confidence: Double?
    ) -> MealItemData {
        MealItemData(id: id, order: 0, foodID: nil, adHocName: name, quantity: Grams(grams), nutrition: values, provenance: provenance, aiRecordID: recordID, confidence: confidence)
    }
}
