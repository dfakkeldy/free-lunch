// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import FLCore
@testable import FLPlate

@Suite("Label OCR")
struct LabelOCRTests {
    @Test("label serving values become per-100 g draft values")
    func parsesFullLabel() {
        guard case .success(let draft) = LabelOCRParser.parse(firstLabel) else {
            Issue.record("Expected label draft")
            return
        }
        #expect(draft.name == "Test Granola")
        #expect(draft.brand == "Synthetic Co")
        #expect(draft.per100g.kcal == 400)
        #expect(draft.per100g.proteinG == 10)
        #expect(draft.per100g.carbsG == 70)
        #expect(abs(draft.per100g.fatG - 8.333333333333334) < 0.000000001)
        #expect(abs((draft.per100g.fiberG ?? -1) - 13.333333333333334) < 0.000000001)
        #expect(draft.origin == .labelOCR)
        #expect(!draft.isLiquid)
        #expect(draft.servings == [ServingDef(name: "1/2 cup", grams: Grams(30))])
    }

    @Test("optional label fields default correctly")
    func optionalFieldsDefault() {
        let source = json("""
        {"name":"Plain Food","servingSizeGrams":45,"kcal":90,"protein":4.5,"carbs":13.5,"fat":2.25}
        """)
        guard case .success(let draft) = LabelOCRParser.parse(source) else {
            Issue.record("Expected label draft")
            return
        }
        #expect(draft.brand == nil)
        #expect(draft.servings == [ServingDef(name: "1 serving", grams: Grams(45))])
        #expect(draft.per100g.kcal == 200)
        #expect(draft.per100g.proteinG == 10)
        #expect(draft.per100g.carbsG == 30)
        #expect(draft.per100g.fatG == 5)
        #expect(draft.per100g.fiberG == nil)
        for source in [
            "{\"name\":\"a\",\"servingSizeGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"fiber\":null}",
            "{\"name\":\"a\",\"servingSizeGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1}"
        ] {
            guard case .success(let nullDraft) = LabelOCRParser.parse(json(source)) else {
                Issue.record("Expected nil fiber to parse")
                return
            }
            #expect(nullDraft.per100g.fiberG == nil)
        }
    }

    @Test("strict label schema rejects malformed values")
    func rejectsInvalidLabels() {
        let cases: [(String, LabelOCRFailure)] = [
            ("not json", .notJSON),
            ("{\"name\":\"x\",\"servingSizeGrams\":0,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1}", .invalidValue(field: "servingSizeGrams")),
            ("{\"name\":\"x\",\"servingSizeGrams\":1,\"kcal\":-1,\"protein\":1,\"carbs\":1,\"fat\":1}", .invalidValue(field: "kcal")),
            ("{\"servingSizeGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1}", .schemaMismatch),
            ("{\"name\":\"x\",\"servingSizeGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"extra\":0}", .schemaMismatch),
            ("{\"name\":\"x\",\"servingSizeGrams\":\"1\",\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1}", .schemaMismatch)
        ]
        for (source, expected) in cases {
            #expect(LabelOCRParser.parse(json(source)) == .failure(expected))
        }
    }

    @Test("a label draft explicitly becomes a label-provenance plate item")
    func createsPlateItem() {
        guard case .success(let draft) = LabelOCRParser.parse(firstLabel),
              let item = draft.plateItem(id: labelID(1), grams: 60)
        else {
            Issue.record("Expected label plate item")
            return
        }
        #expect(item.nutrition.kcal == 240)
        #expect(item.nutrition.proteinG == 6)
        #expect(item.nutrition.carbsG == 42)
        #expect(item.nutrition.fatG == 5)
        #expect(item.nutrition.fiberG == 8)
        #expect(item.provenance == .labelOCR)
        #expect(item.confidence == nil)
        #expect(item.aiRecordID == nil)
        #expect(draft.plateItem(id: labelID(2), grams: 0) == nil)
    }

    @Test("label record completion returns a draft without adding a plate item")
    func appliesLabelResponseWithoutAutoAdd() {
        var plate = CapturePlate(items: [labelManualItem])
        plate.parkCapture(recordID: labelID(3), createdAt: Date(timeIntervalSince1970: 1), kind: .label, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        let beforeItems = plate.items
        let draft = plate.applyLabelResponse(firstLabel, toRecord: labelID(3))
        #expect(draft?.name == "Test Granola")
        #expect(plate.records[0].status == .complete)
        #expect(plate.items == beforeItems)
        #expect(plate.state == .draft)

        plate.parkCapture(recordID: labelID(4), createdAt: Date(timeIntervalSince1970: 2), kind: .label, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        #expect(plate.applyLabelResponse(Data("bad".utf8), toRecord: labelID(4)) == nil)
        #expect(plate.records[1].status == .failed)
        #expect(plate.items == beforeItems)
    }

    @Test("meal and label routes are mutually exclusive")
    func routesRemainExclusive() {
        var plate = CapturePlate()
        plate.parkCapture(recordID: labelID(5), createdAt: Date(timeIntervalSince1970: 3), kind: .label, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        let before = plate
        plate.applyResponse(mealLikeResponse, toRecord: labelID(5), newItemIDs: [labelID(6)])
        #expect(plate == before)
        plate.parkCapture(recordID: labelID(7), createdAt: Date(timeIntervalSince1970: 4), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        #expect(plate.applyLabelResponse(firstLabel, toRecord: labelID(7)) == nil)
        #expect(plate.records[1].status == .pending)
    }
}

private let firstLabel = json("""
{"name":"Test Granola","brand":"Synthetic Co","servingSizeGrams":30,"servingName":"1/2 cup","kcal":120,"protein":3,"carbs":21,"fat":2.5,"fiber":4}
""")

private let mealLikeResponse = json("""
{"items":[{"name":"x","estPortionGrams":1,"kcal":1,"protein":1,"carbs":1,"fat":1,"confidence":0.5}],"note":"x"}
""")

private func json(_ source: String) -> Data {
    Data(source.utf8)
}

private func labelID(_ value: UInt8) -> UUID {
    UUID(uuid: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private let labelManualItem = CapturePlateItem(id: labelID(9), name: "manual", quantityGrams: 1, nutrition: NutritionValues(kcal: Kilocalories(1), protein: Grams(1), carbs: Grams(1), fat: Grams(1)), provenance: .typed, aiRecordID: nil, confidence: nil, userEdited: false)
