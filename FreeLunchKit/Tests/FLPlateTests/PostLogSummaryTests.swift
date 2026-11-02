// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 acceptance #7: the post-log surface shows remaining-vs-target
// above daily totals (text snapshot), and dismissal returns to the
// timeline in one gesture.
//
// Every expected string and number below was worked out by hand from the
// fixture, not read back from the implementation:
// - Target: 2000 kcal, protein 150 g, fat floor 18 % → 360 kcal = 40 g,
//   carbs (2000 − 600 − 360) / 4 = 260 g.
// - Logged today before the plate: 1000 kcal, P 60, C 120, F 30.
// - The plate: 300 kcal P 30 C 20 F 10 + 200 kcal P 0 C 30 F 10
//   = 500 kcal, P 30, C 50, F 20.
// - Day after logging: 1500 kcal, P 90, C 170, F 50.
//   Remaining: 500 kcal, P 60, C 90, F −10. Fat is a floor, so 50 g
//   against a 40 g floor reads "met", not "over".
import FLCore
import FLPlate
import Foundation
import Testing

enum PlateFixture {
    static let target = DailyTarget(kcal: 2_000, proteinG: 150, carbsG: 260, fatFloorG: 40)

    static func totals(_ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double) -> NutritionTotals {
        NutritionTotals(summing: [values(kcal, protein, carbs, fat)])
    }

    static func values(_ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double) -> NutritionValues {
        NutritionValues(kcal: Kilocalories(kcal), protein: Grams(protein), carbs: Grams(carbs), fat: Grams(fat))
    }

    static func id(_ n: Int) -> UUID {
        let digits = String(n)
        let padded = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
        return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
    }

    static let loggedBefore = totals(1_000, 60, 120, 30)
    static let dayAfter = totals(1_500, 90, 170, 50)

    static func plate(state: MealState = .draft) -> MealEntryData {
        MealEntryData(
            id: id(1),
            state: state,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            loggedAt: state == .logged ? Date(timeIntervalSince1970: 1_800_000_600) : nil,
            items: [
                MealItemData(
                    id: id(11), order: 0, foodID: id(21), quantity: Grams(150),
                    nutrition: values(300, 30, 20, 10), provenance: .scaleWeighed
                ),
                MealItemData(
                    id: id(12), order: 1, foodID: nil, adHocName: "Side salad", quantity: Grams(120),
                    nutrition: values(200, 0, 30, 10), provenance: .aiEstimate,
                    aiRecordID: id(31), confidence: 0.6
                )
            ],
            source: .phone
        )
    }
}

@Suite("Post-log surface (spec §2 acceptance #7)")
struct PostLogSummaryTests {
    @Test("snapshot: remaining vs target sits above the daily totals")
    func snapshotWithTarget() {
        let summary = PostLogSummary(dayTotals: PlateFixture.dayAfter, target: PlateFixture.target)

        #expect(summary.snapshot == """
        Remaining today
          500 kcal left of 2000 kcal
          Protein 60 g left of 150 g
          Carbs 90 g left of 260 g
          Fat floor of 40 g met
        Today's totals
          1500 kcal
          P 90 g · C 170 g · F 50 g
        """)
        #expect(summary.sections.map(\.kind) == [.remaining, .dailyTotals])
    }

    @Test("snapshot: no target adopted is an explicit state, still above totals")
    func snapshotWithoutTarget() {
        let summary = PostLogSummary(dayTotals: PlateFixture.dayAfter, target: nil)

        #expect(summary.remaining == .noTargetAdopted)
        #expect(summary.snapshot == """
        Remaining today
          No target adopted
        Today's totals
          1500 kcal
          P 90 g · C 170 g · F 50 g
        """)
    }

    @Test("over target reads as a neutral 'over', never a negative 'left'")
    func overTarget() {
        let summary = PostLogSummary(dayTotals: PlateFixture.totals(2_120, 160, 260, 40), target: PlateFixture.target)

        #expect(summary.sections[0].lines == [
            "120 kcal over 2000 kcal",
            "Protein 10 g over 150 g",
            "Carbs 0 g left of 260 g",
            "Fat floor of 40 g met"
        ])
    }

    @Test("below the fat floor says how much is still to reach it")
    func belowFatFloor() {
        // 2000 − 1200 = 800; 150 − 100 = 50; 260 − 150 = 110; 40 − 25 = 15.
        let summary = PostLogSummary(dayTotals: PlateFixture.totals(1_200, 100, 150, 25), target: PlateFixture.target)

        #expect(summary.sections[0].lines == [
            "800 kcal left of 2000 kcal",
            "Protein 50 g left of 150 g",
            "Carbs 110 g left of 260 g",
            "Fat 15 g to reach 40 g floor"
        ])
    }

    @Test("remaining values are target minus the day's logged totals")
    func remainingValues() {
        let summary = PostLogSummary(dayTotals: PlateFixture.dayAfter, target: PlateFixture.target)

        #expect(summary.remaining == .vsTarget(
            target: PlateFixture.target,
            remaining: MacroAmounts(kcal: 500, proteinG: 60, carbsG: 90, fatG: -10)
        ))
        #expect(summary.dayTotals == MacroAmounts(kcal: 1_500, proteinG: 90, carbsG: 170, fatG: 50))
    }

    @Test("the plate's remaining equals the post-log remaining once logged today")
    func plateAndSheetAgree() {
        let header = PlateHeader(plate: PlateFixture.plate(), loggedToday: PlateFixture.loggedBefore, target: PlateFixture.target)
        let summary = PostLogSummary(dayTotals: PlateFixture.dayAfter, target: PlateFixture.target)

        #expect(header.remaining == summary.remaining)
        #expect(header.remainingText == "500 kcal left today")
    }
}

@Suite("Log flow navigation (spec §2 acceptance #7)")
struct PlateFlowTests {
    @Test("logging pops the plate and presents the sheet over the timeline; one dismissal is the timeline")
    func oneGestureBackToTimeline() {
        var flow = PlateFlow()
        #expect(flow.isOnTimeline)

        flow.open(plateID: PlateFixture.id(1))
        #expect(flow.openPlateID == PlateFixture.id(1))
        #expect(!flow.isOnTimeline)

        let summary = PostLogSummary(dayTotals: PlateFixture.dayAfter, target: nil)
        flow.didLog(summary)
        #expect(flow.openPlateID == nil)
        #expect(flow.postLog == summary)

        flow.dismissPostLog()
        #expect(flow.isOnTimeline)
        #expect(flow.postLog == nil)
        #expect(flow.openPlateID == nil)
    }

    @Test("leaving a plate without logging presents no sheet")
    func closeWithoutLogging() {
        var flow = PlateFlow()
        flow.open(plateID: PlateFixture.id(1))
        flow.closePlate()

        #expect(flow.isOnTimeline)
        #expect(flow.postLog == nil)
    }
}
