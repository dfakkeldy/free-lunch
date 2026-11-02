// SPDX-License-Identifier: GPL-3.0-or-later
// Watch working-set model (spec §1 store shape): RecentFoodSnapshot, the
// phone-pushed typeahead digest. Present in the shared schema; only the
// watch store fills it. The store caps and replaces this digest on every
// phone push, so snapshot rows never accumulate on the watch.
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class RecentFoodSnapshot {
        @Attribute(.unique) var foodID: UUID
        var name: String
        /// Canonical grams; the watch tap-to-log default portion.
        var lastPortionGrams: Double?
        /// Zero-based position in the phone's digest, with lower ranks first.
        var rank: Int

        init(foodID: UUID, name: String, lastPortionGrams: Double?, rank: Int) {
            self.foodID = foodID
            self.name = name
            self.lastPortionGrams = lastPortionGrams
            self.rank = rank
        }
    }
}
