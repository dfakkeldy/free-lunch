// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — HealthKit dietary mirror values (spec §1 amendment, semantics
// §10).
import Foundation

/// A locally cached HealthKit dietary sample. HealthKit remains canonical.
public struct DietarySampleData: Sendable, Hashable, Identifiable {
    public let hkUUID: UUID
    public var date: Date
    /// Canonical kilocalories.
    public private(set) var kcal: Double
    /// Canonical grams; nil when the sample carries no value.
    public private(set) var proteinG: Double?
    public private(set) var carbsG: Double?
    public private(set) var fatG: Double?
    public var sourceBundleID: String
    public var deletedInHK: Bool

    public var id: UUID { hkUUID }

    public init(
        hkUUID: UUID,
        date: Date,
        energy: Kilocalories,
        protein: Grams? = nil,
        carbs: Grams? = nil,
        fat: Grams? = nil,
        sourceBundleID: String,
        deletedInHK: Bool = false
    ) {
        self.hkUUID = hkUUID
        self.date = date
        kcal = energy.value
        proteinG = protein?.value
        carbsG = carbs?.value
        fatG = fat?.value
        self.sourceBundleID = sourceBundleID
        self.deletedInHK = deletedInHK
    }
}
