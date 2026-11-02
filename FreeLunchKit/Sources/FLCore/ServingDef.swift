// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — ServingDef (spec §1 FoodItem.servings)
//
// A named entry convenience ("1 slice" = 32 g). The stored quantity is always
// grams; construction goes through `Grams` or a `Measurement<UnitMass>`.
import Foundation

public struct ServingDef: Sendable, Hashable, Codable {
    public let name: String
    /// Canonical grams for one serving.
    public let grams: Double

    public init(name: String, grams: Grams) {
        self.name = name
        self.grams = grams.value
    }

    /// Accepts any mass unit and stores grams.
    public init(name: String, quantity: Measurement<UnitMass>) throws(CanonicalUnitError) {
        self.init(name: name, grams: try Grams(quantity))
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case grams
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        grams = try container.decode(Grams.self, forKey: .grams).value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(grams, forKey: .grams)
    }
}
