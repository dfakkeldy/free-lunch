// SPDX-License-Identifier: GPL-3.0-or-later
// The adopted target the plate and post-log sheet compare against
// (spec §2 "Plate screen", "Post-log surface").
//
// Hand-computed: adopted 2000 kcal, protein 150 g, fat floor 18 %
// → fat 2000 × 18 / 100 = 360 kcal = 40 g; carbs (2000 − 150×4 − 360) / 4
// = 1040 / 4 = 260 g.
import FLCore
import FLEnergyCore
import Foundation
import Testing
@testable import FLPersistence

private typealias E = EnergyStoreFixture

@MainActor
@Suite("Plate target lookup")
struct PlateTargetLookupTests {
    private func adopt2000(_ store: SwiftDataStore, on day: Date) throws {
        try store.registerFormulaVersion(E.v1Row)
        try store.adoptTarget(
            TargetAdoption(
                calculated: CalculatedTarget(expenditureKcal: 2_400, rateGoal: E.rate(-0.5)),
                adoptedTargetKcal: 2_000,
                macros: E.macros(protein: 150, fatFloorPct: 18),
                formula: .builtinV1
            ),
            on: day,
            calendar: E.calendar,
            id: uid(1)
        )
    }

    @Test("no adopted period: nil, the 'no target adopted' state")
    func noTarget() throws {
        let store = try makeInMemoryStore()
        #expect(try store.adoptedMacroBreakdown(on: E.noon(21), calendar: E.calendar) == nil)
    }

    @Test("the adopted (not calculated) kcal and pinned macros govern the day")
    func adopted() throws {
        let store = try makeInMemoryStore()
        try adopt2000(store, on: E.noon(21))

        let breakdown = try #require(try store.adoptedMacroBreakdown(on: E.noon(22), calendar: E.calendar))
        #expect(breakdown.targetKcal == 2_000)
        #expect(breakdown.proteinG == 150)
        #expect(breakdown.fatFloorG == 40)
        #expect(breakdown.carbsG == 260)

        // Same calendar day as adoption, early morning: governed too.
        #expect(try store.adoptedMacroBreakdown(on: E.morning(21), calendar: E.calendar)?.targetKcal == 2_000)
        // The day before adoption has no target.
        #expect(try store.adoptedMacroBreakdown(on: E.noon(20), calendar: E.calendar) == nil)
    }
}
