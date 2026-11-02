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
                AIEstimationRecordData(id: failedRecordID, createdAt: Date(timeIntervalSince1970: 1), photoID: failedPhotoID, providerTier: 1, modelID: "m", status: .failed, responseJSON: Data("not-json".utf8)),
                AIEstimationRecordData(id: labelRecordID, createdAt: Date(timeIntervalSince1970: 2), photoID: labelPhotoID, providerTier: 1, modelID: "label", status: .complete)
            ],
            items: [MealItemData(id: labelItemID, order: 0, foodID: nil, adHocName: "Label cereal", quantity: Grams(30), nutrition: NutritionValues(kcal: Kilocalories(120), protein: Grams(6), carbs: Grams(12), fat: Grams(4)), provenance: .labelOCR, aiRecordID: labelRecordID, confidence: nil)]
        )
        let plate = CapturePlate(snapshot: snapshot)
        #expect(plate.records[0].status == .failed)
        #expect(plate.records[0].failure != nil)
        #expect(plate.records[0].failure?.userMessage == "Couldn't read this — log manually")
        #expect(plate.records[1].kind == .label)
        #expect(plate.items[0].provenance == .labelOCR)
        #expect(!plate.items[0].userEdited)

        var manualPlate = plate
        manualPlate.addManualItem(CapturePlateItem(id: snapshotID(15), name: "Manual", quantityGrams: 10, nutrition: NutritionValues(kcal: Kilocalories(10), protein: Grams(1), carbs: Grams(1), fat: Grams(1)), provenance: .typed, aiRecordID: nil, confidence: nil, userEdited: false))
        #expect(manualPlate.snapshot(photos: snapshot.photos).items.map(\.id) == [labelItemID])
    }
}

private func snapshotID(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func wire(_ source: String) -> Data {
    Data(source.utf8)
}
