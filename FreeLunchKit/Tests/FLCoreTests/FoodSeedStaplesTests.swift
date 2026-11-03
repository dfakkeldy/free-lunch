// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §11 acceptance #1, last clause: golden values for ten staples checked
// against USDA FoodData Central, and structural checks on the whole bundled
// seed. The expected numbers below were typed from FDC's own JSON for each
// fdcId (the per-food record, nutrients 208, 203, 205, 204, 291), not read
// back from the seed file, so a wrong transcription in the file fails here.
import Foundation
import Testing
@testable import FLCore

@Suite("Bundled food seed: FDC staples and structure")
struct FoodSeedStaplesTests {
    struct Staple {
        let fdcId: Int
        let kcal: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        let fiber: Double
    }

    /// FDC SR Legacy, per 100 g.
    static let staples: [Staple] = [
        Staple(fdcId: 171_477, kcal: 165, protein: 31.02, carbs: 0, fat: 3.57, fiber: 0), // chicken breast, roasted
        Staple(fdcId: 168_878, kcal: 130, protein: 2.69, carbs: 28.17, fat: 0.28, fiber: 0.4), // white rice, cooked
        Staple(fdcId: 171_287, kcal: 143, protein: 12.56, carbs: 0.72, fat: 9.51, fiber: 0), // egg, whole, raw
        Staple(fdcId: 173_944, kcal: 89, protein: 1.09, carbs: 22.84, fat: 0.33, fiber: 2.6), // banana, raw
        Staple(fdcId: 171_265, kcal: 61, protein: 3.15, carbs: 4.8, fat: 3.25, fiber: 0), // whole milk
        Staple(fdcId: 170_379, kcal: 34, protein: 2.82, carbs: 6.64, fat: 0.37, fiber: 2.6), // broccoli, raw
        Staple(fdcId: 175_168, kcal: 206, protein: 22.1, carbs: 0, fat: 12.35, fiber: 0), // Atlantic salmon, farmed, cooked
        Staple(fdcId: 173_735, kcal: 132, protein: 8.86, carbs: 23.71, fat: 0.54, fiber: 8.7), // black beans, cooked
        Staple(fdcId: 170_567, kcal: 579, protein: 21.15, carbs: 21.55, fat: 49.93, fiber: 12.5), // almonds
        Staple(fdcId: 171_413, kcal: 884, protein: 0, carbs: 0, fat: 100, fiber: 0) // olive oil
    ]

    @Test("ten staples match their FoodData Central values exactly")
    func staplesMatchFDC() throws {
        let seed = try FoodCatalogSeed.loadBundled()
        for staple in Self.staples {
            let entry = try #require(seed.foods.first { $0.fdcId == staple.fdcId }, "fdcId \(staple.fdcId) is in the seed")
            let values = entry.per100g
            #expect(entry.fdcDataType == .srLegacy)
            #expect(values.kcal == staple.kcal, "\(entry.name) kcal")
            #expect(values.proteinG == staple.protein, "\(entry.name) protein")
            #expect(values.carbsG == staple.carbs, "\(entry.name) carbs")
            #expect(values.fatG == staple.fat, "\(entry.name) fat")
            #expect(values.fiberG == staple.fiber, "\(entry.name) fiber")
        }
    }

    @Test("the bundled seed is a version-1 catalog of about 300 distinct foods")
    func bundledShape() throws {
        let seed = try FoodCatalogSeed.loadBundled()
        #expect(seed.seedVersion == 1)
        #expect((280...350).contains(seed.foods.count))
        #expect(seed.foods.allSatisfy { $0.since == 1 })
        #expect(Set(seed.foods.map(\.fdcId)).count == seed.foods.count, "each FDC record is seeded once")
        #expect(Set(seed.foods.map(\.id)).count == seed.foods.count)
        // Every entry is public-domain SR Legacy or Foundation data.
        #expect(seed.foods.allSatisfy { $0.fdcDataType == .srLegacy || $0.fdcDataType == .foundation })
    }

    @Test("energy agrees with the macros, except two entries FDC itself publishes oddly")
    func energyIsConsistentWithMacros() throws {
        // kcal vs 4P + 4C + 9F. FDC derives energy with food-specific factors,
        // so the tolerance is wide; it still catches a mistyped digit.
        let published: Set<String> = ["oat-bran-cooked", "cocoa-powder-unsweetened"]
        let seed = try FoodCatalogSeed.loadBundled()
        for entry in seed.foods where !published.contains(entry.key) {
            let values = entry.per100g
            let atwater = 4 * values.proteinG + 4 * values.carbsG + 9 * values.fatG
            #expect(abs(values.kcal - atwater) <= max(25, 0.2 * values.kcal), "\(entry.name): \(values.kcal) vs \(atwater)")
        }
    }

    @Test("most foods carry a household serving, and every serving is a sensible weight")
    func servings() throws {
        let seed = try FoodCatalogSeed.loadBundled()
        let withServings = seed.foods.filter { !$0.servings.isEmpty }
        #expect(Double(withServings.count) / Double(seed.foods.count) > 0.9)
        for serving in seed.foods.flatMap(\.servings) {
            #expect(serving.grams > 0 && serving.grams <= 1_000, "\(serving.name)")
        }
    }
}
