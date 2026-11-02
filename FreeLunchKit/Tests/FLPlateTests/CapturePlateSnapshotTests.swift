// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation
import Testing
@testable import FLPlate

@Suite("CapturePlate snapshot mapping")
struct CapturePlateSnapshotTests {
    @Test("meal capture round trip derives edits and keeps them through a rerun")
    func roundTripAndRerun() {
        let recordID = snapshotID(1)
        let photoID = snapshotID(2)
        let riceID = snapshotID(3)
        let beansID = snapshotID(4)
        let response = wire("""
        {"items":[{"name":"Rice","estPortionGrams":150,"kcal":300,"protein":12,"carbs":30,"fat":10,"confidence":0.8},{"name":"Beans","estPortionGrams":85,"kcal":110,"protein":7,"carbs":20,"fat":0.4,"confidence":0.55}],"note":"synthetic"}
        """)
        var plate = CapturePlate()
        plate.parkCapture(recordID: recordID, createdAt: Date(timeIntervalSince1970: 100), kind: .meal, photoID: photoID, hint: "dinner", providerTier: 2, modelID: "m2")
        plate.applyResponse(response, toRecord: recordID, newItemIDs: [riceID, beansID])
        plate.setQuantity(itemID: riceID, grams: 180)

        let snapshot = plate.snapshot(photos: [PhotoAttachmentData(id: photoID, relativePath: "meal.jpg", capturedAt: Date(timeIntervalSince1970: 99), kind: .meal)])
        #expect(snapshot.records == [AIEstimationRecordData(id: recordID, createdAt: Date(timeIntervalSince1970: 100), photoID: photoID, hint: "dinner", providerTier: 2, modelID: "m2", status: .complete, responseJSON: response, userCorrections: [])])
        #expect(snapshot.items.map(\.id) == [riceID, beansID])
        #expect(snapshot.items.map(\.quantityGrams) == [180, 85])

        var reloaded = CapturePlate(snapshot: snapshot)
        #expect(reloaded.records[0].kind == .meal)
        #expect(reloaded.items[0].userEdited)
        #expect(!reloaded.items[1].userEdited)
        reloaded.addCorrection("more beans", toRecord: recordID)
        reloaded.applyResponse(wire("""
        {"items":[{"name":"Beans","estPortionGrams":100,"kcal":130,"protein":8,"carbs":24,"fat":0.5,"confidence":0.6}],"note":"rerun"}
        """), toRecord: recordID, newItemIDs: [snapshotID(5)])
        #expect(reloaded.items.map(\.id) == [riceID, beansID])
        #expect(reloaded.items[0].quantityGrams == 180)
        #expect(reloaded.items[1].quantityGrams == 100)
        #expect(reloaded.items[1].nutrition == NutritionValues(kcal: Kilocalories(130), protein: Grams(8), carbs: Grams(24), fat: Grams(0.5)))
    }

    @Test("failed and label records reload with capture semantics")
    func failedAndLabelReload() {
        let failedPhotoID = snapshotID(10)
        let failedRecordID = snapshotID(11)
        let labelPhotoID = snapshotID(12)
        let labelRecordID = snapshotID(13)
        let labelItemID = snapshotID(14)
        let snapshot = AICaptureSnapshot(
            photos: [
                PhotoAttachmentData(id: failedPhotoID, relativePath: "failed.jpg", capturedAt: Date(timeIntervalSince1970: 1), kind: .meal),
                PhotoAttachmentData(id: labelPhotoID, relativePath: "label.jpg", capturedAt: Date(timeIntervalSince1970: 2), kind: .label)
            ],
            records: [
                AIEstimationRecordData(id: failedRecordID, createdAt: Date(timeIntervalSince1970: 1), photoID: failedPhotoID, providerTier: 1, modelID: "m", status: .failed, responseJSON: nil),
                AIEstimationRecordData(id: labelRecordID, createdAt: Date(timeIntervalSince1970: 2), photoID: labelPhotoID, providerTier: 1, modelID: "label", status: .complete)
            ],
            items: [MealItemData(id: labelItemID, order: 0, foodID: nil, adHocName: "Label cereal", quantity: Grams(30), nutrition: NutritionValues(kcal: Kilocalories(120), protein: Grams(6), carbs: Grams(12), fat: Grams(4)), provenance: .labelOCR, aiRecordID: labelRecordID, confidence: nil)]
        )
        let plate = CapturePlate(snapshot: snapshot)
        #expect(plate.records[0].status == .failed)
        #expect(plate.records[0].failure == .providerFailed)
        #expect(plate.records[0].failure?.userMessage == "Couldn't read this — log manually")
        #expect(plate.records[1].kind == .label)
        #expect(plate.items[0].provenance == .labelOCR)
        #expect(!plate.items[0].userEdited)

        var manualPlate = plate
        manualPlate.addManualItem(CapturePlateItem(id: snapshotID(15), name: "Manual", quantityGrams: 10, nutrition: NutritionValues(kcal: Kilocalories(10), protein: Grams(1), carbs: Grams(1), fat: Grams(1)), provenance: .typed, aiRecordID: nil, confidence: nil, userEdited: false))
        #expect(manualPlate.snapshot(photos: snapshot.photos).items.map(\.id) == [labelItemID])
    }

    @Test("label draft items link to the newest label record when snapshotted")
    func labelDraftItemsLinkToLatestLabelRecord() {
        let olderRecordID = snapshotID(20)
        let labelRecordID = snapshotID(21)
        let labelItemID = snapshotID(22)
        let labelItem = CapturePlateItem(
            id: labelItemID,
            name: "Synthetic label oats",
            quantityGrams: 40,
            nutrition: NutritionValues(kcal: Kilocalories(160), protein: Grams(8), carbs: Grams(16), fat: Grams(6), fiber: Grams(4)),
            provenance: .labelOCR,
            aiRecordID: nil,
            confidence: nil,
            userEdited: false
        )
        let records = [
            AIEstimationRecordData(id: olderRecordID, createdAt: Date(timeIntervalSince1970: 10), photoID: snapshotID(23), kind: .label, hint: nil, providerTier: 1, modelID: "label", status: .complete, responseJSON: nil, userCorrections: [], failure: nil),
            AIEstimationRecordData(id: labelRecordID, createdAt: Date(timeIntervalSince1970: 20), photoID: snapshotID(24), kind: .label, hint: nil, providerTier: 1, modelID: "label", status: .complete, responseJSON: nil, userCorrections: [], failure: nil)
        ]
        let photos = [
            PhotoAttachmentData(id: snapshotID(23), relativePath: "older-label.jpg", capturedAt: Date(timeIntervalSince1970: 10), kind: .label),
            PhotoAttachmentData(id: snapshotID(24), relativePath: "label.jpg", capturedAt: Date(timeIntervalSince1970: 20), kind: .label)
        ]

        let linked = CapturePlate(items: [labelItem], records: records).snapshot(photos: photos)
        #expect(linked.items.map(\.id) == [labelItemID])
        #expect(linked.items[0].aiRecordID == labelRecordID)

        let unlinked = CapturePlate(items: [labelItem]).snapshot(photos: [])
        #expect(unlinked.items.isEmpty)
    }

    @Test("reload preserves removed response names across a rerun")
    func reloadPreservesRemovedResponseNames() {
        let recordID = snapshotID(30)
        let photoID = snapshotID(31)
        let riceID = snapshotID(32)
        let beansID = snapshotID(33)
        let removedPeasID = snapshotID(34)
        let response = wire("""
        {"items":[{"name":"Rice","estPortionGrams":150,"kcal":300,"protein":12,"carbs":30,"fat":10,"confidence":0.8},{"name":"Beans","estPortionGrams":85,"kcal":110,"protein":7,"carbs":20,"fat":0.4,"confidence":0.55},{"name":"Peas","estPortionGrams":60,"kcal":50,"protein":3,"carbs":9,"fat":0.2,"confidence":0.7}],"note":"synthetic"}
        """)
        let snapshot = AICaptureSnapshot(
            photos: [PhotoAttachmentData(id: photoID, relativePath: "meal.jpg", capturedAt: Date(timeIntervalSince1970: 1), kind: .meal)],
            records: [AIEstimationRecordData(id: recordID, createdAt: Date(timeIntervalSince1970: 1), photoID: photoID, providerTier: 1, modelID: "m", status: .complete, responseJSON: response)],
            items: [
                MealItemData(id: riceID, order: 0, foodID: nil, adHocName: "Rice", quantity: Grams(150), nutrition: NutritionValues(kcal: Kilocalories(300), protein: Grams(12), carbs: Grams(30), fat: Grams(10)), provenance: .aiEstimate, aiRecordID: recordID, confidence: 0.8),
                MealItemData(id: beansID, order: 1, foodID: nil, adHocName: "Beans", quantity: Grams(85), nutrition: NutritionValues(kcal: Kilocalories(110), protein: Grams(7), carbs: Grams(20), fat: Grams(0.4)), provenance: .aiEstimate, aiRecordID: recordID, confidence: 0.55)
            ]
        )

        var reloaded = CapturePlate(snapshot: snapshot)
        reloaded.applyResponse(response, toRecord: recordID, newItemIDs: [riceID, beansID, removedPeasID])

        #expect(reloaded.items.map(\.id) == [riceID, beansID])
        #expect(!reloaded.items.contains { $0.id == removedPeasID })
    }

    @Test("AI estimates with fiber reload as user-edited")
    func aiEstimateWithFiberReloadsAsEdited() {
        let recordID = snapshotID(40)
        let photoID = snapshotID(41)
        let itemID = snapshotID(42)
        let response = wire("""
        {"items":[{"name":"Rice","estPortionGrams":150,"kcal":300,"protein":12,"carbs":30,"fat":10,"confidence":0.8}],"note":"synthetic"}
        """)
        let snapshot = AICaptureSnapshot(
            photos: [PhotoAttachmentData(id: photoID, relativePath: "meal.jpg", capturedAt: Date(timeIntervalSince1970: 1), kind: .meal)],
            records: [AIEstimationRecordData(id: recordID, createdAt: Date(timeIntervalSince1970: 1), photoID: photoID, providerTier: 1, modelID: "m", status: .complete, responseJSON: response)],
            items: [MealItemData(id: itemID, order: 0, foodID: nil, adHocName: "Rice", quantity: Grams(150), nutrition: NutritionValues(kcal: Kilocalories(300), protein: Grams(12), carbs: Grams(30), fat: Grams(10), fiber: Grams(3)), provenance: .aiEstimate, aiRecordID: recordID, confidence: 0.8)]
        )

        #expect(CapturePlate(snapshot: snapshot).items[0].userEdited)
    }
}

private func snapshotID(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func wire(_ source: String) -> Data {
    Data(source.utf8)
}
