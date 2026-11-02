// SPDX-License-Identifier: GPL-3.0-or-later
// Watch working-set model (spec §1 store shape): RecentFoodSnapshot, the
// phone-pushed typeahead digest. Present in the shared schema; only the
// watch store fills it. Capping and pruning land with the watch work.
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class RecentFoodSnapshot {
        @Attribute(.unique) var foodID: UUID
        var name: String
        /// Canonical grams; the watch tap-to-log default portion.
        var lastPortionGrams: Double?

        init(foodID: UUID, name: String, lastPortionGrams: Double?) {
            self.foodID = foodID
            self.name = name
            self.lastPortionGrams = lastPortionGrams
        }
    }
}
