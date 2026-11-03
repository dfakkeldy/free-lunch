// SPDX-License-Identifier: GPL-3.0-or-later
// Where anchored-query positions live between launches. Outside SwiftData on
// purpose: an anchor is a resumable cursor, not user data, and keeping it out
// of the versioned schema means no schema change for it. Losing it is safe:
// the next sync starts again from the beginning of history and the mirror's
// upserts are idempotent.
import Foundation

/// Persists one anchored-query position per Health type.
@MainActor
public protocol HealthAnchorStore: AnyObject {
    func anchor(for type: HealthDataType) -> HealthQueryAnchor?
    /// `nil` forgets the anchor, so the next sync backfills from the start.
    func setAnchor(_ anchor: HealthQueryAnchor?, for type: HealthDataType)
}

/// The default anchor store: one `UserDefaults` data value per type.
@MainActor
public final class UserDefaultsHealthAnchorStore: HealthAnchorStore {
    public static let defaultKeyPrefix = "FreeLunch.HealthAnchor."

    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = UserDefaultsHealthAnchorStore.defaultKeyPrefix) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func anchor(for type: HealthDataType) -> HealthQueryAnchor? {
        defaults.data(forKey: key(for: type)).map(HealthQueryAnchor.init(data:))
    }

    public func setAnchor(_ anchor: HealthQueryAnchor?, for type: HealthDataType) {
        if let anchor {
            defaults.set(anchor.data, forKey: key(for: type))
        } else {
            defaults.removeObject(forKey: key(for: type))
        }
    }

    private func key(for type: HealthDataType) -> String {
        keyPrefix + type.rawValue
    }
}
