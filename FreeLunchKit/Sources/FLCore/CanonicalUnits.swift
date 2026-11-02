// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — canonical units (spec §1, acceptance #5)
//
// Free Lunch stores exactly four units: grams, kilograms, kilocalories and
// milligrams. Pounds, stones, ounces and kilojoules are display-layer
// conversions only. These wrappers are the single construction point for
// every canonical value: the public API accepts `Measurement` in any unit and
// converts once, at construction, so a non-canonical number can never reach a
// stored field. Only the converted `Double` is kept; no `Measurement` is ever
// a stored property.
import Foundation

/// Why a raw value or measurement could not become a canonical quantity.
public enum CanonicalUnitError: Error, Equatable, Sendable {
    case notFinite(Double)
    case negative(Double)
}

/// Exact avoirdupois factors. Foundation's built-in `UnitMass.pounds`,
/// `.ounces` and `.stones` use rounded coefficients (0.453592 kg per pound,
/// for example), so those three units are converted here with the exact
/// international definition (1 lb = 0.45359237 kg); every other unit goes
/// through Foundation unchanged.
enum ExactMass {
    static let gramsPerPound: Double = 453.592_37
    static let gramsPerOunce: Double = 28.349_523_125
    static let gramsPerStone: Double = 6_350.293_18

    static func gramsPerUnit(_ unit: UnitMass) -> Double? {
        if unit == UnitMass.pounds { return gramsPerPound }
        if unit == UnitMass.ounces { return gramsPerOunce }
        if unit == UnitMass.stones { return gramsPerStone }
        return nil
    }

    /// Converts `measurement` to `target`, a metric unit whose size in
    /// grams is `targetGrams` (1 for g, 1000 for kg, 0.001 for mg).
    static func convert(
        _ measurement: Measurement<UnitMass>,
        to target: UnitMass,
        targetGrams: Double
    ) -> Double {
        if let factor = gramsPerUnit(measurement.unit) {
            return measurement.value * factor / targetGrams
        }
        return measurement.converted(to: target).value
    }

    /// Converts a canonical value (in `source`, of size `sourceGrams`) for
    /// display in `unit`.
    static func display(
        _ value: Double,
        from source: UnitMass,
        sourceGrams: Double,
        in unit: UnitMass
    ) -> Double {
        if let factor = gramsPerUnit(unit) {
            return value * sourceGrams / factor
        }
        return Measurement(value: value, unit: source).converted(to: unit).value
    }
}

enum CanonicalValidation {
    static func check(_ value: Double) throws(CanonicalUnitError) -> Double {
        guard value.isFinite else { throw .notFinite(value) }
        guard value >= 0 else { throw .negative(value) }
        return value
    }

    static func requireValid(_ value: Double, _ type: String) -> Double {
        precondition(value.isFinite, "\(type) requires a finite value, got \(value)")
        precondition(value >= 0, "\(type) requires a non-negative value, got \(value)")
        return value
    }

    static func decode(from decoder: Decoder) throws -> Double {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Double.self)
        do {
            return try check(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Canonical quantity must be finite and non-negative (decoded \(raw))."
            )
        }
    }
}

/// A food or serving mass, always stored in grams.
public struct Grams: Sendable, Hashable, Comparable, Codable {
    /// The only stored value. Always grams.
    public let value: Double

    /// Canonical path. Traps on a non-finite or negative value (a caller bug).
    public init(_ grams: Double) {
        value = CanonicalValidation.requireValid(grams, "Grams")
    }

    /// For untrusted raw values (decoded payloads, store read-back).
    public init(validating grams: Double) throws(CanonicalUnitError) {
        value = try CanonicalValidation.check(grams)
    }

    /// Accepts any mass unit (oz, lb, kg, mg...) and stores grams.
    /// Pounds, ounces and stones use the exact avoirdupois definition.
    public init(_ measurement: Measurement<UnitMass>) throws(CanonicalUnitError) {
        try self.init(validating: ExactMass.convert(measurement, to: .grams, targetGrams: 1))
    }

    /// Display-layer conversion; never stored.
    public func value(in unit: UnitMass) -> Double {
        ExactMass.display(value, from: .grams, sourceGrams: 1, in: unit)
    }

    public static func < (lhs: Grams, rhs: Grams) -> Bool { lhs.value < rhs.value }

    public init(from decoder: Decoder) throws {
        value = try CanonicalValidation.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A body weight, always stored in kilograms.
public struct Kilograms: Sendable, Hashable, Comparable, Codable {
    /// The only stored value. Always kilograms.
    public let value: Double

    public init(_ kilograms: Double) {
        value = CanonicalValidation.requireValid(kilograms, "Kilograms")
    }

    public init(validating kilograms: Double) throws(CanonicalUnitError) {
        value = try CanonicalValidation.check(kilograms)
    }

    /// Accepts any mass unit (lb, st, g...) and stores kilograms.
    public init(_ measurement: Measurement<UnitMass>) throws(CanonicalUnitError) {
        try self.init(validating: ExactMass.convert(measurement, to: .kilograms, targetGrams: 1_000))
    }

    public func value(in unit: UnitMass) -> Double {
        ExactMass.display(value, from: .kilograms, sourceGrams: 1_000, in: unit)
    }

    public static func < (lhs: Kilograms, rhs: Kilograms) -> Bool { lhs.value < rhs.value }

    public init(from decoder: Decoder) throws {
        value = try CanonicalValidation.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Food energy, always stored in kilocalories.
public struct Kilocalories: Sendable, Hashable, Comparable, Codable {
    /// The only stored value. Always kcal.
    public let value: Double

    public init(_ kcal: Double) {
        value = CanonicalValidation.requireValid(kcal, "Kilocalories")
    }

    public init(validating kcal: Double) throws(CanonicalUnitError) {
        value = try CanonicalValidation.check(kcal)
    }

    /// Accepts any energy unit (kJ, J, cal...) and stores kcal.
    public init(_ measurement: Measurement<UnitEnergy>) throws(CanonicalUnitError) {
        try self.init(validating: measurement.converted(to: .kilocalories).value)
    }

    public func value(in unit: UnitEnergy) -> Double {
        Measurement(value: value, unit: UnitEnergy.kilocalories).converted(to: unit).value
    }

    public static func < (lhs: Kilocalories, rhs: Kilocalories) -> Bool { lhs.value < rhs.value }

    public init(from decoder: Decoder) throws {
        value = try CanonicalValidation.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A medication dose, always stored in milligrams.
public struct Milligrams: Sendable, Hashable, Comparable, Codable {
    /// The only stored value. Always mg.
    public let value: Double

    public init(_ milligrams: Double) {
        value = CanonicalValidation.requireValid(milligrams, "Milligrams")
    }

    public init(validating milligrams: Double) throws(CanonicalUnitError) {
        value = try CanonicalValidation.check(milligrams)
    }

    /// Accepts any mass unit (µg, g...) and stores milligrams.
    public init(_ measurement: Measurement<UnitMass>) throws(CanonicalUnitError) {
        try self.init(validating: ExactMass.convert(measurement, to: .milligrams, targetGrams: 0.001))
    }

    public func value(in unit: UnitMass) -> Double {
        ExactMass.display(value, from: .milligrams, sourceGrams: 0.001, in: unit)
    }

    public static func < (lhs: Milligrams, rhs: Milligrams) -> Bool { lhs.value < rhs.value }

    public init(from decoder: Decoder) throws {
        value = try CanonicalValidation.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
