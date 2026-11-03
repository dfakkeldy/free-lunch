// SPDX-License-Identifier: GPL-3.0-or-later
// FoodSeedLoader — puts the versioned food seed into a catalog (spec §11).
//
// The pattern is Burly's seed loader, ported over the `FoodCatalogStore`
// boundary: the seed is versioned data, bumps are additive, a load is
// idempotent, and a stored row is never overwritten. All of that follows
// from one rule: a seeded food's id derives from its key (see
// `FoodSeedIdentity`), and the loader inserts exactly the entries whose id
// is not in the store yet.
//
// - Loading twice inserts nothing the second time.
// - A version bump inserts only the new keys.
// - A seeded food the user edited was forked: the original is archived and
//   keeps its id, so it is present and the loader leaves it alone. An
//   archived seeded row is therefore never resurrected, and a user's edits
//   are never overwritten.
//
// Because the check is by id against every stored row, archived ones
// included, there is no seed-version bookkeeping and no schema change.
import FLCore
import Foundation

public enum FoodSeedLoader {
    /// Inserts the entries of `seed` whose id is not in the store, in one
    /// save, and returns how many it inserted. A store that fails the save
    /// is unchanged.
    @MainActor
    @discardableResult
    public static func apply(_ seed: FoodCatalogSeed, to store: some FoodCatalogStore) throws -> Int {
        let existing = Set(try store.foods(includingArchived: true).map(\.id))
        let missing = seed.foodItems().filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return 0 }
        try store.createFoods(missing)
        return missing.count
    }

    /// Loads the bundled seed and applies it. Returning the seed lets a
    /// caller read what was applied without a second resource read.
    @MainActor
    @discardableResult
    public static func applyBundled(to store: some FoodCatalogStore) throws -> FoodCatalogSeed {
        let seed = try FoodCatalogSeed.loadBundled()
        try apply(seed, to: store)
        return seed
    }
}
