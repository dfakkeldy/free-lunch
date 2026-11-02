// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — NutritionValues
//
// The macro set spec §1 uses twice: per-100 g on a FoodItem and as the
// log-time snapshot on a MealItem. kcal plus grams of protein, carbs, fat and
// optional fiber; no micronutrients in v1. Energy accepts kJ (or any energy
// unit) and is stored as kcal.
import Foundation

public struct NutritionValues: Sendable, Hashable, Codable {
    public let kcal: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double
    public let fiberG: Double?

    public init(kcal: Kilocalories, protein: Grams, carbs: Grams, fat: Grams, fiber: Grams? = nil) {
        self.kcal = kcal.value
        self.proteinG = protein.value
        self.carbsG = carbs.value
        self.fatG = fat.value
        self.fiberG = fiber?.value
    }

    /// Accepts any energy and mass units; stores kcal and grams.
    public init(
        energy: Measurement<UnitEnergy>,
        protein: Measurement<UnitMass>,
        carbs: Measurement<UnitMass>,
        fat: Measurement<UnitMass>,
        fiber: Measurement<UnitMass>? = nil
    ) throws(CanonicalUnitError) {
        var fiberGrams: Grams?
        if let fiber {
            fiberGrams = try Grams(fiber)
        }
        self.init(
            kcal: try Kilocalories(energy),
            protein: try Grams(protein),
            carbs: try Grams(carbs),
            fat: try Grams(fat),
            fiber: fiberGrams
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kcal
        case proteinG
        case carbsG
        case fatG
        case fiberG
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kcal = try container.decode(Kilocalories.self, forKey: .kcal).value
        proteinG = try container.decode(Grams.self, forKey: .proteinG).value
        carbsG = try container.decode(Grams.self, forKey: .carbsG).value
        fatG = try container.decode(Grams.self, forKey: .fatG).value
        fiberG = try container.decodeIfPresent(Grams.self, forKey: .fiberG)?.value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kcal, forKey: .kcal)
        try container.encode(proteinG, forKey: .proteinG)
        try container.encode(carbsG, forKey: .carbsG)
        try container.encode(fatG, forKey: .fatG)
        try container.encodeIfPresent(fiberG, forKey: .fiberG)
    }
}
