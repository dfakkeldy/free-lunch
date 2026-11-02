// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #5: the API accepts `Measurement`, stores the converted
// canonical value, and no lb/st/oz/kJ figure is ever kept. Expected values
// come from the exact unit definitions (1 lb = 0.45359237 kg, 1 oz = 1/16 lb,
// 1 st = 14 lb, 1 kcal = 4.184 kJ), worked by hand, not from Foundation.
import FLCore
import Foundation
import Testing

func isClose(_ actual: Double?, _ expected: Double, relative: Double = 1e-12) -> Bool {
    guard let actual else { return false }
    let scale = max(abs(expected), 1)
    return abs(actual - expected) <= relative * scale
}

@Suite("Canonical units: Measurement in, canonical out")
struct CanonicalUnitsTests {
    @Test("pounds, ounces and stones store exact grams")
    func imperialMassToGrams() throws {
        #expect(isClose(try Grams(Measurement(value: 1, unit: UnitMass.pounds)).value, 453.59237))
        #expect(isClose(try Grams(Measurement(value: 3, unit: UnitMass.ounces)).value, 85.048569375))
        #expect(isClose(try Grams(Measurement(value: 1, unit: UnitMass.stones)).value, 6_350.29318))
    }

    @Test("metric masses store grams")
    func metricMassToGrams() throws {
        #expect(isClose(try Grams(Measurement(value: 0.25, unit: UnitMass.kilograms)).value, 250))
        #expect(isClose(try Grams(Measurement(value: 1_500, unit: UnitMass.milligrams)).value, 1.5))
        #expect(try Grams(Measurement(value: 32, unit: UnitMass.grams)).value == 32)
    }

    @Test("body weight in pounds and stones stores kilograms")
    func bodyWeightToKilograms() throws {
        #expect(isClose(try Kilograms(Measurement(value: 1, unit: UnitMass.pounds)).value, 0.45359237))
        #expect(isClose(try Kilograms(Measurement(value: 200, unit: UnitMass.pounds)).value, 90.718474))
        #expect(isClose(try Kilograms(Measurement(value: 14, unit: UnitMass.stones)).value, 88.90410452))
        #expect(isClose(try Kilograms(Measurement(value: 72_500, unit: UnitMass.grams)).value, 72.5))
    }

    @Test("kilojoules and small calories store kilocalories")
    func energyToKilocalories() throws {
        #expect(isClose(try Kilocalories(Measurement(value: 836.8, unit: UnitEnergy.kilojoules)).value, 200))
        #expect(isClose(try Kilocalories(Measurement(value: 4.184, unit: UnitEnergy.kilojoules)).value, 1))
        #expect(isClose(try Kilocalories(Measurement(value: 1_000, unit: UnitEnergy.calories)).value, 1))
        #expect(try Kilocalories(Measurement(value: 250, unit: UnitEnergy.kilocalories)).value == 250)
    }

    @Test("micrograms and grams store milligrams")
    func doseToMilligrams() throws {
        #expect(isClose(try Milligrams(Measurement(value: 250, unit: UnitMass.micrograms)).value, 0.25))
        #expect(isClose(try Milligrams(Measurement(value: 0.0024, unit: UnitMass.grams)).value, 2.4))
        #expect(try Milligrams(Measurement(value: 1, unit: UnitMass.milligrams)).value == 1)
    }

    @Test("display conversions are computed, exact, and never stored")
    func displayConversions() {
        #expect(isClose(Kilograms(100).value(in: .pounds), 220.46226218487757))
        #expect(isClose(Kilograms(6.35029318).value(in: .stones), 1))
        #expect(isClose(Grams(453.59237).value(in: .pounds), 1))
        #expect(isClose(Grams(28.349523125).value(in: .ounces), 1))
        #expect(isClose(Kilocalories(100).value(in: .kilojoules), 418.4))
        #expect(isClose(Milligrams(0.5).value(in: .micrograms), 500))
    }

    @Test("negative and non-finite measurements are rejected")
    func invalidMeasurementsThrow() {
        #expect(throws: CanonicalUnitError.negative(-1)) {
            try Grams(Measurement(value: -1, unit: UnitMass.grams))
        }
        #expect(throws: CanonicalUnitError.self) {
            try Kilograms(Measurement(value: .infinity, unit: UnitMass.pounds))
        }
        #expect(throws: CanonicalUnitError.self) {
            try Kilocalories(Measurement(value: .nan, unit: UnitEnergy.kilojoules))
        }
        #expect(throws: CanonicalUnitError.self) {
            try Milligrams(Measurement(value: -0.25, unit: UnitMass.milligrams))
        }
    }

    @Test("a quantity encodes as its bare canonical number and rejects bad input")
    func quantityCodable() throws {
        let pound = try Grams(Measurement(value: 1, unit: UnitMass.pounds))
        let data = try JSONEncoder().encode([pound])
        let decoded = try JSONSerialization.jsonObject(with: data) as? [Double]
        #expect(isClose(decoded?.first, 453.59237))
        #expect(try JSONDecoder().decode([Grams].self, from: data) == [pound])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([Kilograms].self, from: Data("[-70]".utf8))
        }
    }
}
