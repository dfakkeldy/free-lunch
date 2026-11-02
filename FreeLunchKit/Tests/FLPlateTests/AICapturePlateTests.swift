// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import FLCore
@testable import FLPlate

@Suite("AI capture plate pipeline")
struct AICapturePlateTests {
    @Test("malformed and semantically invalid responses never change plate items")
    func failedResponsesAreAtomic() {
        let recordID = id(1)
        let manualA = manualItem(id: id(2), name: "manual A")
        let manualB = manualItem(id: id(3), name: "manual B")
        var plate = CapturePlate(items: [manualA, manualB])
        plate.parkCapture(recordID: recordID, createdAt: Date(timeIntervalSince1970: 1), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        let beforeItems = plate.items
        plate.applyResponse(Data("garbage".utf8), toRecord: recordID, newItemIDs: [id(4)])
        #expect(plate.records[0].status == .failed)
        #expect(plate.records[0].failure == .notJSON)
        #expect(plate.records[0].responseJSON == nil)
        #expect(plate.items == beforeItems)
        #expect(plate.state == .draft)
        #expect(!plate.items.contains { $0.provenance == .aiEstimate })

        plate.addCorrection("retry", toRecord: recordID)
        plate.applyResponse(badConfidenceResponse, toRecord: recordID, newItemIDs: [id(5)])
        #expect(plate.records[0].status == .failed)
        #expect(plate.records[0].failure == .invalidValue(itemIndex: 0, field: "confidence"))
        #expect(plate.items == beforeItems)
    }

    @Test("runner distinguishes provider failure, offline parking, and later completion")
    func runnerDegradationAndRecovery() async {
        let recordID = id(10)
        var plate = CapturePlate(items: [manualItem(id: id(11), name: "manual")])
        plate.parkCapture(recordID: recordID, createdAt: Date(timeIntervalSince1970: 2), kind: .meal, photoID: id(12), hint: "dinner", providerTier: 1, modelID: "old")
        let beforeFailure = plate.items
        await AICaptureRunner.run(provider: testProvider(.failure(.failed)), recordID: recordID, newItemIDs: [id(13)], on: &plate)
        #expect(plate.records[0].status == .failed)
        #expect(plate.records[0].failure == .providerFailed)
        #expect(plate.items == beforeFailure)

        plate.addCorrection("again", toRecord: recordID)
        let beforeOffline = plate
        await AICaptureRunner.run(provider: testProvider(.failure(.offline)), recordID: recordID, newItemIDs: [id(13)], on: &plate)
        #expect(plate == beforeOffline)
        plate.addManualItem(manualItem(id: id(14), name: "still usable"))
        #expect(plate.items.count == 2)

        await AICaptureRunner.run(provider: testProvider(.data(onlineResponse)), recordID: recordID, newItemIDs: [id(15)], on: &plate)
        #expect(plate.records[0].status == .complete)
        #expect(plate.records[0].providerTier == 9)
        #expect(plate.records[0].modelID == "test-model")
        #expect(plate.items.last?.name == "online")
        #expect(plate.items.last?.provenance == .aiEstimate)
    }

    @Test("runner routes label responses to drafts without changing the plate")
    func runnerHandlesLabelResponses() async {
        var plate = CapturePlate(items: [manualItem(id: id(16), name: "manual")])
        plate.parkCapture(recordID: id(17), createdAt: Date(timeIntervalSince1970: 2), kind: .label, photoID: nil, hint: nil, providerTier: 1, modelID: "old")
        let beforeItems = plate.items

        let draft = await AICaptureRunner.runLabel(provider: testProvider(.data(validLabelResponse)), recordID: id(17), on: &plate)
        #expect(draft?.name == "Synthetic Label")
        #expect(draft?.origin == .labelOCR)
        #expect(draft?.per100g.kcal == 400)
        #expect(draft?.per100g.proteinG == 20)
        #expect(draft?.per100g.carbsG == 40)
        #expect(draft?.per100g.fatG == 16)
        #expect(plate.records[0].status == .complete)
        #expect(plate.records[0].providerTier == 9)
        #expect(plate.records[0].modelID == "test-model")
        #expect(plate.items == beforeItems)
        #expect(plate.state == .draft)

        plate.parkCapture(recordID: id(18), createdAt: Date(timeIntervalSince1970: 2), kind: .label, photoID: nil, hint: nil, providerTier: 1, modelID: "old")
        #expect(await AICaptureRunner.runLabel(provider: testProvider(.data(Data("garbage".utf8))), recordID: id(18), on: &plate) == nil)
        #expect(plate.records[1].status == .failed)
        #expect(plate.records[1].failure != nil)

        plate.parkCapture(recordID: id(19), createdAt: Date(timeIntervalSince1970: 2), kind: .label, photoID: nil, hint: nil, providerTier: 1, modelID: "old")
        #expect(await AICaptureRunner.runLabel(provider: testProvider(.failure(.offline)), recordID: id(19), on: &plate) == nil)
        #expect(plate.records[2].status == .pending)
    }

    @Test("meal runner does not call providers for label records")
    func mealRunnerSkipsLabelRecords() async {
        let counter = ProviderCallCounter()
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(20), createdAt: Date(timeIntervalSince1970: 3), kind: .label, photoID: nil, hint: nil, providerTier: 1, modelID: "old")

        await AICaptureRunner.run(provider: CountingProvider(counter: counter, data: onlineResponse), recordID: id(20), newItemIDs: [id(21)], on: &plate)

        let calls = await counter.value()
        #expect(calls == 0)
        #expect(plate.records[0].status == .pending)
    }

    @Test("garbage provider data fails the record without appending an item")
    func runnerGarbageFails() async {
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(20), createdAt: Date(timeIntervalSince1970: 3), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        await AICaptureRunner.run(provider: testProvider(.data(Data("not-json".utf8))), recordID: id(20), newItemIDs: [id(21)], on: &plate)
        #expect(plate.records[0].status == .failed)
        #expect(plate.records[0].failure == .notJSON)
        #expect(plate.items.isEmpty)
    }

    @Test("first run appends estimated items and retains raw accepted bytes")
    func firstRunAppendsItems() {
        let response = json("""
        {"items":[
        {"name":"Rice","estPortionGrams":150,"kcal":300,"protein":12,"carbs":30,"fat":10,"confidence":0.8},
        {"name":"Beans","estPortionGrams":85,"kcal":110,"protein":7,"carbs":20,"fat":0.4,"confidence":0.55}
        ],"note":"x"}
        """)
        var plate = CapturePlate(items: [manualItem(id: id(30), name: "manual")])
        plate.parkCapture(recordID: id(31), createdAt: Date(timeIntervalSince1970: 4), kind: .meal, photoID: nil, hint: nil, providerTier: 3, modelID: "m")
        plate.applyResponse(response, toRecord: id(31), newItemIDs: [id(32), id(33)])
        #expect(plate.state == .draft)
        #expect(plate.items.map(\.id) == [id(30), id(32), id(33)])
        #expect(plate.items[1].provenance == .aiEstimate)
        #expect(plate.items[1].aiRecordID == id(31))
        #expect(plate.items[1].confidence == 0.8)
        #expect(plate.items[1].quantityGrams == 150)
        #expect(plate.items[1].nutrition == NutritionValues(kcal: Kilocalories(300), protein: Grams(12), carbs: Grams(30), fat: Grams(10)))
        #expect(plate.items[2].confidence == 0.55)
        #expect(plate.records[0].status == .complete)
        #expect(plate.records[0].responseJSON == response)
    }

    @Test("only log changes a draft state")
    func onlyLogChangesState() async {
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(40), createdAt: Date(timeIntervalSince1970: 5), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        plate.applyResponse(singleXResponse, toRecord: id(40), newItemIDs: [id(41)])
        #expect(plate.state == .draft)
        plate.addCorrection("bad", toRecord: id(40))
        plate.applyResponse(Data("bad".utf8), toRecord: id(40), newItemIDs: [id(42)])
        #expect(plate.state == .draft)
        await AICaptureRunner.run(provider: testProvider(.failure(.failed)), recordID: id(40), newItemIDs: [id(42)], on: &plate)
        #expect(plate.state == .draft)
        plate.log()
        #expect(plate.state == .logged)
    }

    @Test("quantity editing retains AI provenance and link")
    func editingAIQuantityPreservesProvenance() {
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(50), createdAt: Date(timeIntervalSince1970: 6), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        plate.applyResponse(editableAIResponse, toRecord: id(50), newItemIDs: [id(51)])
        plate.setQuantity(itemID: id(51), grams: 100)
        let item = plate.items[0]
        #expect(item.quantityGrams == 100)
        #expect(item.nutrition.kcal == 200)
        #expect(item.nutrition.proteinG == 8)
        #expect(item.nutrition.carbsG == 20)
        #expect(abs(item.nutrition.fatG - 6.666666666666667) < 0.000000001)
        #expect(item.provenance == .aiEstimate)
        #expect(item.aiRecordID == id(50))
        #expect(item.confidence == 0.8)
        #expect(item.userEdited)
        let edited = plate.items[0]
        plate.setQuantity(itemID: id(51), grams: 0)
        plate.setQuantity(itemID: id(51), grams: -5)
        plate.setQuantity(itemID: id(51), grams: .nan)
        #expect(plate.items[0] == edited)
    }

    @Test("reruns replace slots in place, insert extras, and remove leftover slots")
    func rerunsReplaceInPlace() {
        var plate = seededRerunPlate()
        let originalIDs = plate.items.map(\.id)
        plate.addCorrection(" that's two cups ", toRecord: id(61))
        #expect(plate.records[0].userCorrections == ["that's two cups"])
        #expect(plate.records[0].status == .pending)
        #expect(plate.items.map(\.name) == ["manual A", "X1", "X2", "manual B"])

        plate.applyResponse(rerunTwoResponse, toRecord: id(61), newItemIDs: [id(70), id(71)])
        #expect(plate.items.map(\.id) == originalIDs)
        #expect(plate.items.map(\.name) == ["manual A", "N1", "N2", "manual B"])

        plate.addCorrection("three", toRecord: id(61))
        plate.applyResponse(rerunThreeResponse, toRecord: id(61), newItemIDs: [id(72), id(73), id(74)])
        #expect(plate.items.map(\.name) == ["manual A", "A", "B", "C", "manual B"])
        #expect(plate.items[3].id == id(74))

        plate.addCorrection("one", toRecord: id(61))
        plate.applyResponse(rerunOneResponse, toRecord: id(61), newItemIDs: [id(75)])
        #expect(plate.items.map(\.name) == ["manual A", "Only", "manual B"])
    }

    @Test("edited items win over reruns and failures retain the previous estimate")
    func rerunKeepsEditedItems() {
        var plate = seededRerunPlate()
        plate.setQuantity(itemID: id(63), grams: 50)
        let edited = plate.items[1]
        plate.addCorrection("correct", toRecord: id(61))
        plate.applyResponse(editedNameResponse, toRecord: id(61), newItemIDs: [id(80), id(81)])
        #expect(plate.items.map(\.name) == ["manual A", "X1", "replacement", "manual B"])
        #expect(plate.items[1] == edited)
        #expect(plate.items[2].id == id(64))

        let beforeFailure = plate.items
        plate.addCorrection("fail", toRecord: id(61))
        plate.applyResponse(Data("garbage".utf8), toRecord: id(61), newItemIDs: [id(82)])
        #expect(plate.records[0].status == .failed)
        #expect(plate.records[0].userCorrections == ["correct", "fail"])
        #expect(plate.items == beforeFailure)
    }

    @Test("failed reruns retain the accepted raw response")
    func failedRerunRetainsPreviousResponse() {
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(83), createdAt: Date(timeIntervalSince1970: 6), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        plate.applyResponse(editableAIResponse, toRecord: id(83), newItemIDs: [id(84)])
        let acceptedResponse = plate.records[0].responseJSON

        plate.addCorrection("retry", toRecord: id(83))
        plate.applyResponse(Data("garbage".utf8), toRecord: id(83), newItemIDs: [id(85)])

        #expect(plate.records[0].status == .failed)
        #expect(plate.records[0].responseJSON == acceptedResponse)
    }

    @Test("renamed and nutrition-edited AI items win matching reruns")
    func editedNameAndNutritionSurviveRerun() {
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(86), createdAt: Date(timeIntervalSince1970: 6), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        plate.applyResponse(editableAIResponse, toRecord: id(86), newItemIDs: [id(87)])
        let editedNutrition = NutritionValues(kcal: Kilocalories(321), protein: Grams(12), carbs: Grams(34), fat: Grams(5), fiber: Grams(2))
        plate.rename(itemID: id(87), to: "  Renamed entrée  ")
        plate.setNutrition(itemID: id(87), editedNutrition)
        let edited = plate.items[0]
        plate.setNutrition(itemID: id(87), NutritionValues(kcal: Kilocalories(-1), protein: Grams(0), carbs: Grams(0), fat: Grams(0)))
        #expect(plate.items[0] == edited)

        plate.addCorrection("keep my edit", toRecord: id(86))
        plate.applyResponse(renamedItemResponse, toRecord: id(86), newItemIDs: [id(88)])

        #expect(plate.items == [edited])
        #expect(plate.items[0].name == "Renamed entrée")
        #expect(plate.items[0].nutrition == editedNutrition)
        #expect(plate.items[0].userEdited)
        #expect(plate.items[0].provenance == .aiEstimate)
        #expect(plate.items[0].aiRecordID == id(86))
        #expect(plate.items[0].confidence == 0.8)
    }

    @Test("removed AI names do not return on rerun while remaining slots replace in place")
    func removedAIItemsStayRemoved() {
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(89), createdAt: Date(timeIntervalSince1970: 6), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        plate.applyResponse(twoItemResponse, toRecord: id(89), newItemIDs: [id(90), id(91)])
        plate.removeItem(id: id(90))

        plate.addCorrection("remove first", toRecord: id(89))
        plate.applyResponse(removedItemRerunResponse, toRecord: id(89), newItemIDs: [id(92), id(93)])

        #expect(plate.items.map(\.name) == ["Updated second"])
        #expect(plate.items[0].id == id(91))
    }

    @Test("missing generated item IDs do not reject a valid response")
    func responseGeneratesMissingItemIDs() {
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(94), createdAt: Date(timeIntervalSince1970: 6), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        plate.applyResponse(twoItemResponse, toRecord: id(94), newItemIDs: [id(95)])

        #expect(plate.records[0].status == .complete)
        #expect(plate.items.count == 2)
        #expect(plate.items[0].id == id(95))
        #expect(plate.items[1].id != id(95))
    }

    @Test("cancelled providers leave records pending and plates unchanged")
    func cancelledProviderLeavesPending() async {
        var plate = CapturePlate(items: [manualItem(id: id(96), name: "manual")])
        plate.parkCapture(recordID: id(97), createdAt: Date(timeIntervalSince1970: 6), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        let before = plate

        await AICaptureRunner.run(provider: testProvider(.cancelled), recordID: id(97), newItemIDs: [id(98)], on: &plate)

        #expect(plate == before)
        #expect(plate.records[0].status == .pending)
    }

    @Test("rerunning one record does not touch another record")
    func recordsRemainIsolated() {
        var plate = CapturePlate()
        plate.parkCapture(recordID: id(90), createdAt: Date(timeIntervalSince1970: 7), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        plate.parkCapture(recordID: id(91), createdAt: Date(timeIntervalSince1970: 8), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
        plate.applyResponse(firstRecordResponse, toRecord: id(90), newItemIDs: [id(92)])
        plate.applyResponse(secondRecordResponse, toRecord: id(91), newItemIDs: [id(93)])
        let second = plate.items[1]
        plate.addCorrection("redo", toRecord: id(90))
        plate.applyResponse(replacedFirstRecordResponse, toRecord: id(90), newItemIDs: [id(94)])
        #expect(plate.items[1] == second)
    }

    @Test("estimation records round trip including a failure")
    func recordCodableRoundTrip() throws {
        let record = AIEstimationRecordData(id: id(100), createdAt: Date(timeIntervalSince1970: 9), photoID: id(101), kind: .meal, hint: "hint", providerTier: 2, modelID: "model", status: .failed, responseJSON: nil, userCorrections: ["fix"], failure: .invalidValue(itemIndex: 0, field: "kcal"))
        let decoded = try JSONDecoder().decode(AIEstimationRecordData.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }
}

private enum TestProviderOutcome: Sendable {
    case data(Data)
    case failure(AICaptureProviderError)
    case cancelled
}

private struct TestProvider: AICaptureProvider {
    let outcome: TestProviderOutcome
    let tier: Int = 9
    let modelID: String = "test-model"

    func estimate(_ request: AICaptureRequest) async throws -> Data {
        switch outcome {
        case .data(let data): data
        case .failure(let error): throw error
        case .cancelled: throw CancellationError()
        }
    }
}

private actor ProviderCallCounter {
    private var calls = 0

    func recordCall() {
        calls += 1
    }

    func value() -> Int {
        calls
    }
}

private struct CountingProvider: AICaptureProvider {
    let counter: ProviderCallCounter
    let data: Data
    let tier = 9
    let modelID = "test-model"

    func estimate(_ request: AICaptureRequest) async throws -> Data {
        await counter.recordCall()
        return data
    }
}

private func testProvider(_ outcome: TestProviderOutcome) -> TestProvider { TestProvider(outcome: outcome) }

private func json(_ source: String) -> Data {
    Data(source.utf8)
}

private func id(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

private func manualItem(id: UUID, name: String) -> CapturePlateItem {
    CapturePlateItem(id: id, name: name, quantityGrams: 100, nutrition: NutritionValues(kcal: Kilocalories(100), protein: Grams(10), carbs: Grams(10), fat: Grams(10)), provenance: .typed, aiRecordID: nil, confidence: nil, userEdited: false)
}

private let badConfidenceResponse = json("""
{"items":[{"name":"bad","estPortionGrams":50,"kcal":10,"protein":1,"carbs":1,"fat":1,"confidence":1.2}],"note":"x"}
""")
private let onlineResponse = json("""
{"items":[{"name":"online","estPortionGrams":25,"kcal":50,"protein":2,"carbs":5,"fat":1,"confidence":0.8}],"note":"x"}
""")
private let singleXResponse = json("""
{"items":[{"name":"x","estPortionGrams":1,"kcal":1,"protein":1,"carbs":1,"fat":1,"confidence":0.5}],"note":"x"}
""")
private let editableAIResponse = json("""
{"items":[{"name":"x","estPortionGrams":150,"kcal":300,"protein":12,"carbs":30,"fat":10,"confidence":0.8}],"note":"x"}
""")
private let validLabelResponse = json("""
{"name":"Synthetic Label","servingSizeGrams":25,"kcal":100,"protein":5,"carbs":10,"fat":4}
""")
private let renamedItemResponse = json("""
{"items":[{"name":"renamed entrée","estPortionGrams":200,"kcal":1,"protein":1,"carbs":1,"fat":1,"confidence":0.1}],"note":"x"}
""")
private let twoItemResponse = json("""
{"items":[{"name":"First","estPortionGrams":10,"kcal":10,"protein":1,"carbs":1,"fat":1,"confidence":0.5},{"name":"Second","estPortionGrams":20,"kcal":20,"protein":2,"carbs":2,"fat":2,"confidence":0.6}],"note":"x"}
""")
private let removedItemRerunResponse = json("""
{"items":[{"name":" first ","estPortionGrams":100,"kcal":100,"protein":10,"carbs":10,"fat":10,"confidence":0.1},{"name":"Updated second","estPortionGrams":30,"kcal":30,"protein":3,"carbs":3,"fat":3,"confidence":0.7}],"note":"x"}
""")
private let rerunTwoResponse = json("""
{"items":[{"name":"N1","estPortionGrams":10,"kcal":10,"protein":1,"carbs":1,"fat":1,"confidence":0.5},{"name":"N2","estPortionGrams":20,"kcal":20,"protein":2,"carbs":2,"fat":2,"confidence":0.6}],"note":"x"}
""")
private let rerunThreeResponse = json("""
{"items":[{"name":"A","estPortionGrams":10,"kcal":10,"protein":1,"carbs":1,"fat":1,"confidence":0.5},{"name":"B","estPortionGrams":20,"kcal":20,"protein":2,"carbs":2,"fat":2,"confidence":0.6},{"name":"C","estPortionGrams":30,"kcal":30,"protein":3,"carbs":3,"fat":3,"confidence":0.7}],"note":"x"}
""")
private let rerunOneResponse = json("""
{"items":[{"name":"Only","estPortionGrams":10,"kcal":10,"protein":1,"carbs":1,"fat":1,"confidence":0.5}],"note":"x"}
""")
private let editedNameResponse = json("""
{"items":[{"name":"x1","estPortionGrams":10,"kcal":10,"protein":1,"carbs":1,"fat":1,"confidence":0.5},{"name":"replacement","estPortionGrams":20,"kcal":20,"protein":2,"carbs":2,"fat":2,"confidence":0.6}],"note":"x"}
""")
private let firstRecordResponse = json("""
{"items":[{"name":"first","estPortionGrams":10,"kcal":10,"protein":1,"carbs":1,"fat":1,"confidence":0.5}],"note":"x"}
""")
private let secondRecordResponse = json("""
{"items":[{"name":"second","estPortionGrams":20,"kcal":20,"protein":2,"carbs":2,"fat":2,"confidence":0.5}],"note":"x"}
""")
private let replacedFirstRecordResponse = json("""
{"items":[{"name":"new first","estPortionGrams":30,"kcal":30,"protein":3,"carbs":3,"fat":3,"confidence":0.5}],"note":"x"}
""")

private func seededRerunPlate() -> CapturePlate {
    var plate = CapturePlate(items: [manualItem(id: id(62), name: "manual A"), manualItem(id: id(65), name: "manual B")])
    plate.parkCapture(recordID: id(61), createdAt: Date(timeIntervalSince1970: 10), kind: .meal, photoID: nil, hint: nil, providerTier: 1, modelID: "m")
    plate.items.insert(CapturePlateItem(id: id(63), name: "X1", quantityGrams: 100, nutrition: NutritionValues(kcal: Kilocalories(100), protein: Grams(10), carbs: Grams(10), fat: Grams(10)), provenance: .aiEstimate, aiRecordID: id(61), confidence: 0.5, userEdited: false), at: 1)
    plate.items.insert(CapturePlateItem(id: id(64), name: "X2", quantityGrams: 100, nutrition: NutritionValues(kcal: Kilocalories(100), protein: Grams(10), carbs: Grams(10), fat: Grams(10)), provenance: .aiEstimate, aiRecordID: id(61), confidence: 0.5, userEdited: false), at: 2)
    return plate
}
