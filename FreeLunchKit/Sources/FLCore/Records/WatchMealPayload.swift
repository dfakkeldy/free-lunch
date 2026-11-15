// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A watch meal or immutable append; nutrition is resolved by the phone.
public struct WatchMealPayload: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public let itemID: UUID
        public let foodID: UUID
        public let quantityGrams: Double
        public init(itemID: UUID, foodID: UUID, quantityGrams: Double) {
            self.itemID = itemID
            self.foodID = foodID
            self.quantityGrams = quantityGrams
        }
    }
    public let mealID: UUID
    public let state: MealState
    public let source: MealSource
    public let createdAt: Date
    public let loggedAt: Date?
    public let hunger: Int?
    public let items: [Item]
    public init(mealID: UUID, state: MealState, source: MealSource, createdAt: Date,
                loggedAt: Date?, hunger: Int?, items: [Item]) {
        self.mealID = mealID
        self.state = state
        self.source = source
        self.createdAt = createdAt
        self.loggedAt = loggedAt
        self.hunger = hunger
        self.items = items
    }
}
