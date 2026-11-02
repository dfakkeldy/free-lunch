// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 "Weighing flows" and acceptance #3 at the level the app drives
// them: the quantity step's provenance, and a plate scale session writing
// through a stand-in for the store.
import FLCore
import FLFixtures
import Foundation
import Testing
@testable import FLPlate

private let foodID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

/// Stands in for the store: records every write the session makes.
private struct RecordedWrite: Equatable {
    let grams: Double
    let provenance: ItemProvenance
}

private struct WriteFailed: Error {}

@Suite("Spec §2 weighing flows")
struct WeighingFlowsTests {
    // MARK: Add-then-weigh

    @Test("a grams reading in the quantity step is a scale reading")
    func quantityStepGramsIsScaleWeighed() {
        let step = QuantityStep(foodID: foodID, food: PlateFoodInfo(name: "Oats"), prefillGrams: 162.5)
        #expect(step.mode == .grams)
        #expect(step.resolvedGrams == Grams(162.5))
        #expect(step.provenance == .scaleWeighed)
    }

    @Test("picking a ServingDef stays typed")
    func quantityStepServingIsTyped() {
        let slice = ServingDef(name: "slice", grams: Grams(32))
        var step = QuantityStep(
            foodID: foodID, food: PlateFoodInfo(name: "Bread", servings: [slice]), prefillGrams: nil
        )
        step.mode = .serving(slice)
        step.servingCountText = "2"
        #expect(step.resolvedGrams == Grams(64))
        #expect(step.provenance == .typed)
    }

    @Test("a liquid's millilitre field is a measure, not a scale reading")
    func quantityStepLiquidIsTyped() {
        let step = QuantityStep(
            foodID: foodID, food: PlateFoodInfo(name: "Milk", isLiquid: true), prefillGrams: 250
        )
        #expect(step.provenance == .typed)
    }

    // MARK: Weigh-as-you-go, cumulative (acceptance #3)

    @Test("cumulative fixture: exact grams per item, the misread never persists")
    func cumulativeFixture() throws {
        var session = PlateScaleSession(mode: .cumulative)
        var store: [RecordedWrite] = []

        for step in WeighingFlowFixtures.cumulative {
            if step.expectedGrams == nil {
                let before = session
                #expect(throws: ScaleEntryError.rejected(.negativeDelta(reading: 400, previous: 412.5))) {
                    try session.add(reading: step.reading) { grams, provenance in
                        store.append(RecordedWrite(grams: grams.value, provenance: provenance))
                    }
                }
                #expect(session == before)
            } else {
                try session.add(reading: step.reading) { grams, provenance in
                    store.append(RecordedWrite(grams: grams.value, provenance: provenance))
                }
            }
        }

        // 250 − 0, 412.5 − 250, (400 refused), 475 − 412.5, 537.25 − 475.
        #expect(store == [
            RecordedWrite(grams: 250, provenance: .scaleWeighed),
            RecordedWrite(grams: 162.5, provenance: .scaleWeighed),
            RecordedWrite(grams: 62.5, provenance: .scaleWeighed),
            RecordedWrite(grams: 62.25, provenance: .scaleWeighed)
        ])
        #expect(store.map(\.grams) == WeighingFlowFixtures.cumulative.compactMap(\.expectedGrams))
        #expect(session.itemCount == 4)
        #expect(session.lastReading == 537.25)
    }

    @Test("an unchanged cumulative total adds nothing and asks again")
    func cumulativeUnchangedTotal() throws {
        var session = PlateScaleSession(mode: .cumulative)
        var writes = 0
        try session.add(reading: 300) { _, _ in writes += 1 }
        #expect(throws: ScaleEntryError.nothingAdded) {
            try session.add(reading: 300) { _, _ in writes += 1 }
        }
        #expect(writes == 1)
        #expect(session.lastReading == 300)
    }

    @Test("a failed store write leaves the baseline where it was")
    func failedWriteDoesNotAdvance() throws {
        var session = PlateScaleSession(mode: .cumulative)
        try session.add(reading: 200) { _, _ in }
        let before = session

        #expect(throws: WriteFailed.self) {
            try session.add(reading: 350) { _, _ in throw WriteFailed() }
        }
        #expect(session == before)
        #expect(session.lastReading == 200)

        // Retrying the same reading measures from the old baseline.
        let grams = try session.add(reading: 350) { grams, _ in grams }
        #expect(grams == Grams(150))
    }

    @Test("preview does not change the session")
    func previewIsPure() throws {
        var session = PlateScaleSession(mode: .cumulative)
        try session.add(reading: 250) { _, _ in }
        let before = session
        #expect(try session.grams(forReading: 412.5) == Grams(162.5))
        #expect(session == before)
        #expect(ScaleSessionText.preview(Grams(162.5)) == "Adds 162.5 g")
    }

    // MARK: Weigh-as-you-go, tared

    @Test("tared fixture: each reading is the item; 0 g is refused")
    func taredFixture() throws {
        var session = PlateScaleSession(mode: .tared)
        var store: [RecordedWrite] = []

        for step in WeighingFlowFixtures.tared {
            if step.expectedGrams == nil {
                #expect(throws: ScaleEntryError.nothingAdded) {
                    try session.add(reading: step.reading) { grams, provenance in
                        store.append(RecordedWrite(grams: grams.value, provenance: provenance))
                    }
                }
            } else {
                try session.add(reading: step.reading) { grams, provenance in
                    store.append(RecordedWrite(grams: grams.value, provenance: provenance))
                }
            }
        }

        #expect(store == [
            RecordedWrite(grams: 45, provenance: .scaleWeighed),
            RecordedWrite(grams: 120.25, provenance: .scaleWeighed),
            RecordedWrite(grams: 8.5, provenance: .scaleWeighed)
        ])
        #expect(session.itemCount == 3)
        #expect(session.lastReading == nil)
    }

    @Test("negative and non-finite readings are refused in either mode")
    func invalidReadings() {
        for mode in [ScaleSessionMode.tared, .cumulative] {
            var session = PlateScaleSession(mode: mode)
            #expect(throws: ScaleEntryError.rejected(.negativeReading(-5))) {
                try session.add(reading: -5) { _, _ in }
            }
            #expect(throws: ScaleEntryError.rejected(.notFinite(.infinity))) {
                try session.add(reading: .infinity) { _, _ in }
            }
            #expect(session.itemCount == 0)
        }
    }

    // MARK: Both flows agree

    @Test("both flows hand the store the same provenance")
    func flowsAgreeOnProvenance() {
        let step = QuantityStep(foodID: foodID, food: PlateFoodInfo(name: "Oats"), prefillGrams: 62.5)
        #expect(step.provenance == PlateScaleSession.provenance)
        #expect(PlateScaleSession.provenance == .scaleWeighed)
    }

    // MARK: Wording

    @Test("re-entry prompts and status lines")
    func wording() throws {
        #expect(
            ScaleSessionText.prompt(
                for: .rejected(.negativeDelta(reading: 400, previous: 412.5)), mode: .cumulative
            ) == "400 g is less than the last total of 412.5 g. Check the scale and enter the new total."
        )
        #expect(
            ScaleSessionText.prompt(for: .nothingAdded, mode: .cumulative)
                == "The total hasn't changed. Add the food, then enter the new total."
        )
        #expect(
            ScaleSessionText.prompt(for: .nothingAdded, mode: .tared)
                == "The reading is 0 g. Add the food, then enter the reading."
        )
        #expect(
            ScaleSessionText.prompt(for: .rejected(.negativeReading(-1)), mode: .tared)
                == "Enter the number the scale shows, in grams."
        )

        var session = PlateScaleSession(mode: .cumulative)
        #expect(ScaleSessionText.status(session) == "Tare the empty bowl once, then add food")
        try session.add(reading: 412.5) { _, _ in }
        #expect(ScaleSessionText.status(session) == "Scale showed 412.5 g")
        #expect(ScaleSessionText.status(PlateScaleSession(mode: .tared)) == "Tare, add the food, enter the reading")
        #expect(ScaleSessionText.readingFieldLabel(.cumulative) == "Total on the scale (g)")
        #expect(ScaleSessionText.readingFieldLabel(.tared) == "Scale reading (g)")
    }
}
