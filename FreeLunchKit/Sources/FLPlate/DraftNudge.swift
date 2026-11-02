// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation

public enum DraftNudge {
    public static let threshold: TimeInterval = 24 * 3600

    public static func isStale(_ meal: MealEntryData, now: Date) -> Bool {
        meal.state == .draft && now.timeIntervalSince(meal.createdAt) > threshold
    }

    public static func staleDrafts(in meals: [MealEntryData], now: Date) -> [MealEntryData] {
        meals
            .filter { isStale($0, now: now) }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
