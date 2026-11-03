// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — versioned catalog seed (spec §11, "Catalog seed").
//
// The bundled JSON is product data, not a fixture: about 300 generic whole
// foods whose per-100 g values are USDA FoodData Central values (public
// domain). Every entry carries its FDC id and data type so a value can be
// traced back to its source record. This file only decodes, validates and
// maps the data; `FoodSeedLoader` in FLPersistence puts it into a store.
//
// ## Identity
//
// A seeded food's `id` is derived from its stable `key`: a name-based
// (version 5) UUID over a fixed namespace. The id is therefore the same on
// every device and in every release, and "is this seed row already in the
// store?" is a lookup by id. That one rule gives the loader its guarantees:
// loading twice inserts nothing; a version bump inserts only the new keys;
// an archived or forked row keeps its id and is never resurrected.
//
// ## Versioning rules
//
// - Additive only. A new `seedVersion` adds entries (each stamped with the
//   version that introduced it in `since`). Never change a shipped entry's
//   `key`, and never edit a shipped entry's values in place: devices that
//   already hold the row would keep the old values, because the loader
//   never overwrites a stored row. A correction ships as a new key.
// - `seedVersion` is the highest `since` in the file.
// - The values are mutable in place only until a build that contains the
//   seed ships.
//
// ## Energy
//
// `kcal` is FDC nutrient 208 ("Energy", kcal) as published; this seed uses
// SR Legacy records only, where 208 is always present, so no value is
// derived from the Atwater factors here.
import CryptoKit
import Foundation

/// The FDC data set a seeded value comes from.
public enum FDCDataType: String, Sendable, Hashable, Codable {
    case srLegacy = "SR Legacy"
    case foundation = "Foundation"
}

/// Why a seed could not be loaded or is not valid.
public enum FoodSeedError: Error, Equatable, Sendable {
    case bundledResourceNotFound
    case invalidSeedVersion(Int)
    case invalidKey(String)
    case duplicateKey(String)
    /// Two distinct keys derived the same id.
    case duplicateID(UUID)
    case emptyName(key: String)
    /// Two entries whose names match once case and diacritics are folded.
    case duplicateName(String)
    case invalidFDCID(key: String)
    /// A negative or non-finite value, or macros that cannot fit in 100 g.
    case invalidValue(key: String)
    case invalidServing(key: String)
    /// `since` outside `1...seedVersion`.
    case invalidSince(key: String)
}

/// Derivation of a seeded food's id from its stable key.
public enum FoodSeedIdentity {
    /// Fixed namespace for Free Lunch's seeded foods. Never change it: every
    /// seeded id on every device derives from it.
    public static let namespace = UUID(uuidString: "6F1D2C84-3B7A-4E59-9C06-A2D81E5B47F3")!

    /// Version 5 (SHA-1, name-based) UUID of `key` in `namespace`.
    public static func id(forKey key: String) -> UUID {
        var input = Data()
        withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
        input.append(contentsOf: key.utf8)

        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// One seeded food.
public struct FoodSeedEntry: Sendable, Hashable, Identifiable {
    /// Permanent identity. Lowercase letters, digits and hyphens.
    public let key: String
    public let name: String
    public let fdcId: Int
    public let fdcDataType: FDCDataType
    /// Canonical nutrition per 100 g, as published by FDC.
    public let per100g: NutritionValues
    public let isLiquid: Bool
    public let servings: [ServingDef]
    /// The seed version that introduced this entry.
    public let since: Int

    public var id: UUID { FoodSeedIdentity.id(forKey: key) }

    public init(
        key: String,
        name: String,
        fdcId: Int,
        fdcDataType: FDCDataType,
        per100g: NutritionValues,
        isLiquid: Bool,
        servings: [ServingDef],
        since: Int
    ) {
        self.key = key
        self.name = name
        self.fdcId = fdcId
        self.fdcDataType = fdcDataType
        self.per100g = per100g
        self.isLiquid = isLiquid
        self.servings = servings
        self.since = since
    }

    /// The catalog row this entry seeds: `.seeded`, never used, not archived.
    public func foodItemData() -> FoodItemData {
        FoodItemData(
            id: id,
            name: name,
            per100g: per100g,
            isLiquid: isLiquid,
            servings: servings,
            origin: .seeded
        )
    }
}

public struct FoodCatalogSeed: Sendable, Equatable {
    public let seedVersion: Int
    public let foods: [FoodSeedEntry]

    /// Throws a `FoodSeedError` if the seed is not valid.
    public init(seedVersion: Int, foods: [FoodSeedEntry]) throws {
        self.seedVersion = seedVersion
        self.foods = foods
        try validate()
    }

    public init(jsonData: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: jsonData)
        var entries: [FoodSeedEntry] = []
        entries.reserveCapacity(file.foods.count)
        for raw in file.foods {
            try entries.append(raw.entry())
        }
        try self.init(seedVersion: file.seedVersion, foods: entries)
    }

    /// Loads the bundled `food-seed.json`.
    public static func loadBundled() throws -> FoodCatalogSeed {
        guard let url = Bundle.module.url(forResource: "food-seed", withExtension: "json") else {
            throw FoodSeedError.bundledResourceNotFound
        }
        return try FoodCatalogSeed(jsonData: Data(contentsOf: url))
    }

    /// The seed as it stood at `version`: only the entries introduced by
    /// then. A device that last loaded `version` holds exactly these rows.
    public func entries(introducedThrough version: Int) -> [FoodSeedEntry] {
        foods.filter { $0.since <= version }
    }

    /// The seed's rows as catalog items, in file order.
    public func foodItems() -> [FoodItemData] {
        foods.map { $0.foodItemData() }
    }

    // MARK: - Validation

    /// Folds case and diacritics, so "Café" and "cafe" are one name.
    static func foldedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "-"
        }
    }

    private func validate() throws {
        guard seedVersion > 0 else { throw FoodSeedError.invalidSeedVersion(seedVersion) }

        var keys: Set<String> = []
        var ids: Set<UUID> = []
        var names: Set<String> = []
        for food in foods {
            guard Self.isValidKey(food.key) else { throw FoodSeedError.invalidKey(food.key) }
            guard keys.insert(food.key).inserted else { throw FoodSeedError.duplicateKey(food.key) }
            guard ids.insert(food.id).inserted else { throw FoodSeedError.duplicateID(food.id) }

            let folded = Self.foldedName(food.name)
            guard !folded.isEmpty else { throw FoodSeedError.emptyName(key: food.key) }
            guard names.insert(folded).inserted else { throw FoodSeedError.duplicateName(food.name) }

            guard food.fdcId > 0 else { throw FoodSeedError.invalidFDCID(key: food.key) }
            guard (1...seedVersion).contains(food.since) else { throw FoodSeedError.invalidSince(key: food.key) }

            let values = food.per100g
            let macros = [values.kcal, values.proteinG, values.carbsG, values.fatG] + (values.fiberG.map { [$0] } ?? [])
            guard macros.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  values.proteinG + values.carbsG + values.fatG <= 100.5,
                  (values.fiberG ?? 0) <= values.carbsG + 0.001,
                  values.kcal <= 925
            else { throw FoodSeedError.invalidValue(key: food.key) }

            var servingNames: Set<String> = []
            for serving in food.servings {
                guard serving.grams.isFinite, serving.grams > 0,
                      !serving.name.trimmingCharacters(in: .whitespaces).isEmpty,
                      servingNames.insert(serving.name).inserted
                else { throw FoodSeedError.invalidServing(key: food.key) }
            }
        }
    }

    // MARK: - JSON shape

    private struct File: Decodable {
        let seedVersion: Int
        let foods: [RawFood]
    }

    /// The flat per-entry JSON shape. Values arrive as plain numbers and are
    /// range-checked before they reach the canonical-unit types, which trap
    /// on a negative or non-finite value.
    private struct RawFood: Decodable {
        let key: String
        let name: String
        let fdcId: Int
        let dataType: FDCDataType
        let kcal: Double
        let proteinG: Double
        let carbsG: Double
        let fatG: Double
        let fiberG: Double?
        let isLiquid: Bool
        let servings: [ServingDef]
        let since: Int

        func entry() throws -> FoodSeedEntry {
            let numbers = [kcal, proteinG, carbsG, fatG] + (fiberG.map { [$0] } ?? [])
            guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw FoodSeedError.invalidValue(key: key)
            }
            return FoodSeedEntry(
                key: key,
                name: name,
                fdcId: fdcId,
                fdcDataType: dataType,
                per100g: NutritionValues(
                    kcal: Kilocalories(kcal),
                    protein: Grams(proteinG),
                    carbs: Grams(carbsG),
                    fat: Grams(fatG),
                    fiber: fiberG.map { Grams($0) }
                ),
                isLiquid: isLiquid,
                servings: servings,
                since: since
            )
        }
    }
}
