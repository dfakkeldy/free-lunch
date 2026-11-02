// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — the phone-pushed recent-food digest for the watch working set.
import Foundation

/// A watch typeahead item, ranked by the phone's digest (best first).
/// `lastPortionGrams` is canonical grams when the phone has a useful default.
public struct RecentFoodSnapshotData: Sendable, Hashable, Codable, Identifiable {
    public let foodID: UUID
    public var name: String
    public var lastPortionGrams: Double?

    public var id: UUID { foodID }

    public init(foodID: UUID, name: String, lastPortionGrams: Double?) {
        self.foodID = foodID
        self.name = name
        self.lastPortionGrams = lastPortionGrams
    }
}
