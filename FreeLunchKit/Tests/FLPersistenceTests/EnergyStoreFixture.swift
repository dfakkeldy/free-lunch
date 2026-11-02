// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic fixture for the energy-binding suites (fl-m3-04).
//
// - Calendar: Gregorian pinned to UTC (`utcCalendar`), a day is 86 400 s.
// - Meals: one logged native plate per day 0...40 at 12:30, two ad-hoc
//   items of 1000 kcal each, so 2000 kcal/day read back from the store.
// - Weight: a hand-set trend of 80 − 0.0625·k kg at 07:00 on days −22...40
//   (the weight lane is out of scope here; it hands the engine a series).
//   Over any 21-day window Δtrend = −0.0625 × 21 = −1.3125 kg.
//
// Expected values, computed by hand and with a throwaway script outside the
// repo from the spec §3 formula text (not from this code's output):
// - FL-EB v1 (ρ 7700), any tracking day: 2000 + 1.3125 × 7700 / 21 = 2481.25
// - synthetic v2 (ρ 7000):               2000 + 1.3125 × 7000 / 21 = 2437.5
// - rate −0.5 kg/wk: −550 kcal/day at ρ 7700, −500 at ρ 7000.
import FLCore
import FLEnergyCore
import Foundation
@testable import FLPersistence

enum EnergyStoreFixture {
    /// 2026-01-05 00:00:00 UTC, a synthetic midnight.
    static let origin = Date(timeIntervalSince1970: 1_767_571_200)

    static func day(_ offset: Int) -> Date {
        origin.addingTimeInterval(Double(offset) * 86_400)
    }

    static func morning(_ offset: Int) -> Date {
        day(offset).addingTimeInterval(7 * 3_600)
    }

    static func noon(_ offset: Int) -> Date {
        day(offset).addingTimeInterval(12.5 * 3_600)
    }

    static let calendar = utcCalendar

    static let weights = TrendSeries(
        smoothing: .standard,
        points: (-22...40).map {
            let kg = 80 - 0.0625 * Double($0)
            return TrendPoint(measuredAt: morning($0), weightKg: kg, trendKg: kg)
        }
    )

    /// Same expression as FL-EB v1 with ρ = 7000 kcal/kg.
    static let v2 = EnergyFormulaVersion(
        name: "FL-EB v2 (synthetic)",
        origin: .builtin("FL-EB v2"),
        parameters: ExpenditureParameters(energyDensityKcalPerKg: 7_000)!
    )

    static let v1Row = StoredFormulaVersion.builtinV1(id: uid(9_001), createdAt: day(-30))
    static let v2Row = StoredFormulaVersion(
        id: uid(9_002),
        formula: v2,
        definition: EnergyFormulaVersion.builtinV1Definition,
        createdAt: day(27)
    )

    /// The plate logged on `offset`.
    static func mealID(_ offset: Int) -> UUID { uid(5_000 + offset) }

    static func kcal(_ value: Double) -> NutritionValues {
        nutrition(value, 0, 0, 0)
    }

    /// Logs the fixture's 2000 kcal plate on each day in `days`.
    @MainActor
    static func logMeals(_ store: SwiftDataStore, days: ClosedRange<Int> = 0...40) throws {
        for offset in days {
            let items = (0..<2).map { index in
                MealItemData(
                    id: uid(6_000 + offset * 10 + index),
                    order: index,
                    foodID: nil,
                    adHocName: "Synthetic plate part \(index)",
                    quantity: Grams(500),
                    nutrition: kcal(1_000),
                    provenance: .typed
                )
            }
            try store.createMeal(
                MealEntryData(
                    id: mealID(offset),
                    state: .logged,
                    createdAt: noon(offset),
                    loggedAt: noon(offset),
                    items: items,
                    source: .phone
                )
            )
        }
    }

    static func rate(_ kgPerWeek: Double) -> RateGoal {
        RateGoal(kgPerWeek: kgPerWeek)!
    }

    static func macros(protein: Double = 128, fatFloorPct: Double = 20) -> MacroTargets {
        MacroTargets(proteinTargetG: protein, fatFloorPct: fatFloorPct)!
    }

    /// Deterministic JSON bytes, for byte-identity checks.
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
