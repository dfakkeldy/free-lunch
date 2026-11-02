// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #5 at the value types: what a type keeps (its stored
// properties and its encoded form) is canonical only. A value built from
// pounds, ounces or kilojoules holds and writes grams/kcal/mg, and no type
// keeps a `Measurement`.
import FLCore
import Foundation
import Testing

private func storedPropertyTypes(_ value: Any) -> [String] {
    Mirror(reflecting: value).children.map { String(describing: type(of: $0.value)) }
}

private struct NotAJSONObject: Error {}

private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NotAJSONObject()
    }
    return object
}

@Suite("Canonical storage: no non-canonical value is kept")
struct CanonicalStorageTests {
    @Test("ServingDef from ounces keeps and encodes grams only")
    func servingFromOunces() throws {
        let slice = try ServingDef(name: "1 slice", quantity: Measurement(value: 2, unit: UnitMass.ounces))
        #expect(isClose(slice.grams, 56.69904625))

        let json = try jsonObject(slice)
        #expect(Set(json.keys) == ["name", "grams"])
        #expect(json["name"] as? String == "1 slice")
        #expect(isClose(json["grams"] as? Double, 56.69904625))
    }

    @Test("ServingDef from grams keeps the exact value")
    func servingFromGrams() {
        let slice = ServingDef(name: "1 slice", grams: Grams(32))
        #expect(slice.grams == 32)
    }

    @Test("NutritionValues from kJ and ounces keeps kcal and grams")
    func nutritionFromNonCanonical() throws {
        let values = try NutritionValues(
            energy: Measurement(value: 836.8, unit: UnitEnergy.kilojoules),
            protein: Measurement(value: 1, unit: UnitMass.ounces),
            carbs: Measurement(value: 12_000, unit: UnitMass.milligrams),
            fat: Measurement(value: 5, unit: UnitMass.grams),
            fiber: Measurement(value: 0.002, unit: UnitMass.kilograms)
        )
        #expect(isClose(values.kcal, 200))
        #expect(isClose(values.proteinG, 28.349523125))
        #expect(isClose(values.carbsG, 12))
        #expect(values.fatG == 5)
        #expect(isClose(values.fiberG, 2))

        let json = try jsonObject(values)
        #expect(Set(json.keys) == ["kcal", "proteinG", "carbsG", "fatG", "fiberG"])
        #expect(isClose(json["kcal"] as? Double, 200))
        #expect(isClose(json["proteinG"] as? Double, 28.349523125))
    }

    @Test("NutritionValues without fiber omits it")
    func nutritionWithoutFiber() throws {
        let values = NutritionValues(kcal: Kilocalories(52), protein: Grams(0.3), carbs: Grams(14), fat: Grams(0.2))
        #expect(values.fiberG == nil)
        #expect(try jsonObject(values)["fiberG"] == nil)
        let round = try JSONDecoder().decode(NutritionValues.self, from: JSONEncoder().encode(values))
        #expect(round == values)
    }

    @Test("ShotEventData from micrograms keeps and encodes milligrams")
    func shotFromMicrograms() throws {
        let medication = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        var shot = try ShotEventData(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            takenAt: Date(timeIntervalSince1970: 1_767_600_000),
            dose: Measurement(value: 250, unit: UnitMass.micrograms),
            medicationID: medication,
            site: .thighLeft,
            source: .watch
        )
        #expect(isClose(shot.doseMg, 0.25))

        let json = try jsonObject(shot)
        #expect(Set(json.keys) == ["id", "takenAt", "doseMg", "medicationID", "site", "source"])
        #expect(isClose(json["doseMg"] as? Double, 0.25))

        shot.setDose(Milligrams(0.5))
        #expect(shot.doseMg == 0.5)
        let round = try JSONDecoder().decode(ShotEventData.self, from: JSONEncoder().encode(shot))
        #expect(round == shot)
    }

    @Test("decoding a negative stored quantity is rejected")
    func decodingRejectsNegative() {
        let serving = Data(#"{"name":"bad","grams":-5}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ServingDef.self, from: serving)
        }
        let shot = Data(#"""
        {"id":"00000000-0000-0000-0000-000000000001","takenAt":0,"doseMg":-1,
         "medicationID":"00000000-0000-0000-0000-000000000901","source":"phone"}
        """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ShotEventData.self, from: shot)
        }
    }

    @Test("no FLCore value type keeps a Measurement as a stored property")
    func noStoredMeasurements() throws {
        let samples: [Any] = [
            Grams(1), Kilograms(1), Kilocalories(1), Milligrams(1),
            ServingDef(name: "x", grams: Grams(1)),
            NutritionValues(kcal: Kilocalories(1), protein: Grams(1), carbs: Grams(1), fat: Grams(1), fiber: Grams(1)),
            ShotEventData(takenAt: Date(), dose: Milligrams(1), medicationID: UUID()),
            MedicationProfileData(known: .tirzepatide)
        ]
        for sample in samples {
            let types = storedPropertyTypes(sample)
            #expect(!types.isEmpty)
            #expect(types.allSatisfy { !$0.contains("Measurement") }, "\(type(of: sample)) stores \(types)")
        }
    }
}
