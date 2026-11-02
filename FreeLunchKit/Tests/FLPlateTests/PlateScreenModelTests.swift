// SPDX-License-Identifier: GPL-3.0-or-later
// Plate screen presentation values (spec §2 "Plate screen", "Typeahead",
// "Hunger"). Expected values are worked out by hand; see the fixture notes
// in PostLogSummaryTests.swift.
import FLCore
import FLPlate
import Foundation
import Testing

@Suite("Plate item rows and provenance glyphs")
struct PlateItemRowTests {
    let oats = PlateFoodInfo(name: "Rolled oats", servings: [ServingDef(name: "cup", grams: Grams(75))])

    @Test("rows show name, grams or serving, kcal and the provenance glyph")
    func rows() {
        let items = PlateFixture.plate().items
        let scaled = PlateItemRow(item: items[0], food: oats)
        let ai = PlateItemRow(item: items[1], food: nil)

        #expect(scaled.name == "Rolled oats")
        #expect(scaled.quantityText == "2 × cup (150 g)")
        #expect(scaled.kcalText == "300 kcal")
        #expect(scaled.glyph == ProvenanceGlyph(symbolName: "scalemass", label: "Scale"))

        #expect(ai.name == "Side salad")
        #expect(ai.quantityText == "120 g")
        #expect(ai.kcalText == "200 kcal")
        #expect(ai.glyph == ProvenanceGlyph(symbolName: "sparkles", label: "AI estimate"))
    }

    @Test("every provenance maps to its glyph; typed items carry none")
    func glyphTable() {
        #expect(ProvenanceGlyph.forProvenance(.typed) == nil)
        #expect(ProvenanceGlyph.forProvenance(.aiEstimate)?.label == "AI estimate")
        #expect(ProvenanceGlyph.forProvenance(.labelOCR) == ProvenanceGlyph(symbolName: "text.viewfinder", label: "Label"))
        #expect(ProvenanceGlyph.forProvenance(.scaleWeighed)?.label == "Scale")
        #expect(ProvenanceGlyph.forProvenance(.imported)?.label == "Imported")
    }

    @Test("an AI item keeps its 'AI estimate' glyph after its grams are edited")
    func aiGlyphSurvivesEdit() {
        var item = PlateFixture.plate().items[1]
        item.setQuantity(Grams(60))
        let row = PlateItemRow(item: item, food: nil)

        #expect(row.quantityText == "60 g")
        #expect(row.glyph?.label == "AI estimate")
    }

    @Test("quantity text: liquids in ml, non-multiples of a serving in grams, one decimal at most")
    func quantityText() {
        #expect(PlateFormat.quantity(grams: 250, isLiquid: true, servings: []) == "250 ml")
        #expect(PlateFormat.quantity(grams: 100, isLiquid: false, servings: oats.servings) == "100 g")
        #expect(PlateFormat.quantity(grams: 75, isLiquid: false, servings: oats.servings) == "1 × cup (75 g)")
        #expect(PlateFormat.quantity(grams: 37.5, isLiquid: false, servings: oats.servings) == "37.5 g")
        #expect(PlateFormat.quantity(grams: 12.34, isLiquid: false, servings: []) == "12.3 g")
    }

    @Test("a catalog item whose food is missing still renders")
    func unknownFood() {
        let row = PlateItemRow(item: PlateFixture.plate().items[0], food: nil)
        #expect(row.name == "Unknown food")
        #expect(row.quantityText == "150 g")
    }
}

@Suite("Plate header: running total and remaining")
struct PlateHeaderTests {
    @Test("running total, macro line and Atwater macro-bar shares")
    func runningTotal() {
        let header = PlateHeader(plate: PlateFixture.plate(), loggedToday: PlateFixture.loggedBefore, target: PlateFixture.target)

        #expect(header.plateTotal == MacroAmounts(kcal: 500, proteinG: 30, carbsG: 50, fatG: 20))
        #expect(header.plateTotalText == "500 kcal")
        #expect(header.plateMacrosText == "P 30 g · C 50 g · F 20 g")
        // 30×4 = 120, 50×4 = 200, 20×9 = 180; of 500.
        #expect(header.macroBar.protein == 0.24)
        #expect(header.macroBar.carbs == 0.40)
        #expect(header.macroBar.fat == 0.36)
    }

    @Test("a draft counts toward today's remaining as if logged now")
    func draftRemaining() {
        let header = PlateHeader(plate: PlateFixture.plate(), loggedToday: PlateFixture.loggedBefore, target: PlateFixture.target)

        #expect(header.remaining == .vsTarget(
            target: PlateFixture.target,
            remaining: MacroAmounts(kcal: 500, proteinG: 60, carbsG: 90, fatG: -10)
        ))
        #expect(header.remainingText == "500 kcal left today")
    }

    @Test("a logged plate is already in today's totals and is not added twice")
    func loggedNotDoubleCounted() {
        let header = PlateHeader(plate: PlateFixture.plate(state: .logged), loggedToday: PlateFixture.dayAfter, target: PlateFixture.target)
        #expect(header.remainingText == "500 kcal left today")
    }

    @Test("over target and no target")
    func overAndNoTarget() {
        let over = PlateHeader(plate: PlateFixture.plate(), loggedToday: PlateFixture.totals(1_620, 0, 0, 0), target: PlateFixture.target)
        #expect(over.remainingText == "120 kcal over today")

        let none = PlateHeader(plate: PlateFixture.plate(), loggedToday: PlateFixture.loggedBefore, target: nil)
        #expect(none.remaining == .noTargetAdopted)
        #expect(none.remainingText == "No target adopted")
    }

    @Test("an empty plate has a zero total and an empty macro bar")
    func emptyPlate() {
        let empty = MealEntryData(createdAt: Date(timeIntervalSince1970: 0), source: .phone)
        let header = PlateHeader(plate: empty, loggedToday: .zero, target: PlateFixture.target)

        #expect(header.plateTotalText == "0 kcal")
        #expect(header.macroBar == MacroBarFractions(.zero))
        #expect(header.macroBar.protein == 0 && header.macroBar.carbs == 0 && header.macroBar.fat == 0)
        #expect(header.remainingText == "2000 kcal left today")
    }
}

@Suite("Hunger control")
struct HungerControlTests {
    @Test("1–5, untouched is unknown, tapping the selected value clears it")
    func toggling() {
        #expect(HungerControl.values == [1, 2, 3, 4, 5])
        #expect(HungerControl.tapped(3, current: nil) == 3)
        #expect(HungerControl.tapped(4, current: 3) == 4)
        #expect(HungerControl.tapped(3, current: 3) == nil)
        #expect(HungerControl.tapped(0, current: 2) == 2)
        #expect(HungerControl.tapped(6, current: nil) == nil)
    }
}

@Suite("Quantity step")
struct QuantityStepTests {
    let foodID = PlateFixture.id(21)
    let oats = PlateFoodInfo(name: "Rolled oats", servings: [ServingDef(name: "cup", grams: Grams(75))])

    @Test("prefilled from the typeahead row's last portion: one tap confirms the habitual portion")
    func prefillFromTypeahead() throws {
        let food = TypeaheadFood(
            id: foodID, name: "Rolled oats", useCount: 4,
            lastUsedAt: Date(timeIntervalSince1970: 1_800_000_000), lastPortionGrams: 40
        )
        let rows = Typeahead.rows(query: "", foods: [food], now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .food(picked, _, prefill) = try #require(rows.first) else {
            Issue.record("expected a food row first")
            return
        }
        let step = QuantityStep(foodID: picked.id, food: oats, prefillGrams: prefill)

        #expect(step.gramsText == "40")
        #expect(step.resolvedGrams == Grams(40))
    }

    @Test("grams input: decimal prefill, comma separator, invalid input refused")
    func gramsInput() {
        #expect(QuantityStep(foodID: foodID, food: oats, prefillGrams: 37.5).gramsText == "37.5")

        var step = QuantityStep(foodID: foodID, food: oats, prefillGrams: nil)
        #expect(step.gramsText == "")
        #expect(step.resolvedGrams == nil)

        step.gramsText = "42,5"
        #expect(step.resolvedGrams == Grams(42.5))
        for bad in ["0", "-5", "abc", "inf", "nan"] {
            step.gramsText = bad
            #expect(step.resolvedGrams == nil, "\(bad)")
        }
    }

    @Test("serving input: count × serving grams")
    func servingInput() {
        var step = QuantityStep(foodID: foodID, food: oats, prefillGrams: 40)
        step.mode = .serving(oats.servings[0])
        #expect(step.resolvedGrams == Grams(75))

        step.servingCountText = "2"
        #expect(step.resolvedGrams == Grams(150))
        step.servingCountText = "0.5"
        #expect(step.resolvedGrams == Grams(37.5))
        step.servingCountText = ""
        #expect(step.resolvedGrams == nil)
        // 1333 × 75 g = 99 975 g, under the 100 000 cap; 1334 × 75 = 100 050 g, over it.
        step.servingCountText = "1333"
        #expect(step.resolvedGrams == Grams(99_975))
        step.servingCountText = "1334"
        #expect(step.resolvedGrams == nil)
    }

    @Test("absurd readings are refused before they reach the store")
    func absurdGramsRefused() {
        var step = QuantityStep(foodID: foodID, food: oats, prefillGrams: nil)
        step.gramsText = "100000"
        #expect(step.resolvedGrams == Grams(100_000))
        for bad in ["100000.1", "1e300", "1e6"] {
            step.gramsText = bad
            #expect(step.resolvedGrams == nil, "\(bad)")
        }
    }
}

@Suite("Plate number formatting")
struct PlateFormatTests {
    @Test("whole numbers round halves away from zero and never print -0")
    func whole() {
        #expect(PlateFormat.whole(0.5) == "1")
        #expect(PlateFormat.whole(2.5) == "3")
        #expect(PlateFormat.whole(1_499.5) == "1500")
        #expect(PlateFormat.whole(-0.4) == "0")
        #expect(PlateFormat.whole(-1.5) == "-2")
    }

    @Test("left/over phrasing around zero")
    func leftOrOver() {
        #expect(PlateFormat.leftOrOver(0.4, unit: "g") == "0 g left")
        #expect(PlateFormat.leftOrOver(-0.4, unit: "g") == "0 g left")
        #expect(PlateFormat.leftOrOver(-0.5, unit: "g") == "1 g over")
    }

    @Test("a fat floor is reached or met, never 'over'")
    func againstFloor() {
        #expect(PlateFormat.againstFloor(15, floor: 40, name: "Fat", unit: "g") == "Fat 15 g to reach 40 g floor")
        #expect(PlateFormat.againstFloor(0.6, floor: 40, name: "Fat", unit: "g") == "Fat 1 g to reach 40 g floor")
        #expect(PlateFormat.againstFloor(0.4, floor: 40, name: "Fat", unit: "g") == "Fat floor of 40 g met")
        #expect(PlateFormat.againstFloor(0, floor: 40, name: "Fat", unit: "g") == "Fat floor of 40 g met")
        #expect(PlateFormat.againstFloor(-10, floor: 40, name: "Fat", unit: "g") == "Fat floor of 40 g met")
    }

    @Test("huge or non-finite values print a placeholder instead of trapping")
    func hugeValuesDoNotTrap() {
        #expect(PlateFormat.whole(1e300) == "–")
        #expect(PlateFormat.whole(-1e300) == "–")
        #expect(PlateFormat.decimal(1e300) == "–")
        #expect(PlateFormat.decimal(.infinity) == "–")
        #expect(PlateFormat.whole(.nan) == "–")
        #expect(PlateFormat.whole(999_999_999) == "999999999")
        #expect(PlateFormat.decimal(123_456.75) == "123456.8")
    }
}
