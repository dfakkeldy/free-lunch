// SPDX-License-Identifier: GPL-3.0-or-later
// HealthKit-free values for the Health adapter (spec §1 Weight, §6, §11
// Health access). Nothing here imports HealthKit: the concrete adapter maps
// these to and from HealthKit types, and tests drive a mock with them.
import FLCore
import Foundation

/// Each Apple Health type Free Lunch reads or writes, the key for per-type
/// authorization status and per-type query anchors.
///
/// Extension point: the dietary types (§10 nutrition import) join as new
/// cases here, with their own anchored-change and write methods on
/// `HealthStoreAdapter` and their own sync service beside
/// `HealthWeightSync`. The anchor store and the Settings status list need no
/// change for that: both are keyed by this enum.
public enum HealthDataType: String, CaseIterable, Sendable, Hashable {
    /// Body weight. Read for the mirror; written by manual weigh-ins.
    case bodyMass
}

/// Whether Free Lunch may write a type, as HealthKit reports it.
///
/// HealthKit reports write ("sharing") access only. Read access is never
/// revealed, for privacy: a denied read looks exactly like an empty history.
/// So there is deliberately no read status here.
public enum HealthAuthorizationStatus: String, Sendable, Hashable {
    /// Health data isn't available on this device.
    case unavailable
    /// The user hasn't been asked yet.
    case notDetermined
    /// The user turned writing off for this type.
    case sharingDenied
    /// The user allowed writing this type.
    case sharingAuthorized
}

/// Whether asking for access would still show the system sheet. HealthKit
/// shows it once per type; after that the user changes access in the
/// Health app or Settings, and the re-request path says so.
public enum HealthAuthorizationRequestStatus: String, Sendable, Hashable {
    case unknown
    /// At least one type hasn't been asked about yet.
    case shouldRequest
    /// Every type has been asked about; the sheet won't appear again.
    case unnecessary
}

/// One row of the Settings "Health access" list.
public struct HealthAccessStatus: Sendable, Hashable {
    public let type: HealthDataType
    /// Write access. Read access is not observable (see
    /// `HealthAuthorizationStatus`).
    public let sharing: HealthAuthorizationStatus

    public init(type: HealthDataType, sharing: HealthAuthorizationStatus) {
        self.type = type
        self.sharing = sharing
    }
}

/// An opaque, persistable anchored-query position. The concrete adapter
/// archives HealthKit's anchor into `data`; nothing else looks inside.
public struct HealthQueryAnchor: Sendable, Hashable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// One page of weight changes after an anchor.
public struct HealthWeightChanges: Sendable, Hashable {
    /// Samples added since the anchor, as HealthKit stores them.
    public let added: [WeightSampleData]
    /// HealthKit UUIDs of samples deleted since the anchor.
    public let deleted: [UUID]
    /// Added samples the adapter couldn't express as a weight (a value no
    /// `Kilograms` holds). They are left out of `added` but still count
    /// toward the page, so a page of only these doesn't end the pass.
    public let unreadable: Int
    /// The position after this page; pass it to the next query.
    public let anchor: HealthQueryAnchor

    public init(added: [WeightSampleData], deleted: [UUID], unreadable: Int = 0, anchor: HealthQueryAnchor) {
        precondition(unreadable >= 0, "unreadable must not be negative")
        self.added = added
        self.deleted = deleted
        self.unreadable = unreadable
        self.anchor = anchor
    }

    /// True for the page after the last change: the pass is done.
    public var isEmpty: Bool { added.isEmpty && deleted.isEmpty && unreadable == 0 }
}

/// The ways Apple Health can be out of reach. Each is a degraded state the
/// app shows, never a crash.
public enum HealthAccessError: Error, Equatable, Sendable {
    /// Health data isn't available on this device.
    case unavailable
    /// The user hasn't been asked for access to this type.
    case authorizationNotDetermined(HealthDataType)
    /// The user denied access to this type.
    case authorizationDenied(HealthDataType)
    /// Apple Health can't be read right now, typically because the device
    /// is locked. A later pass, once it is unlocked, carries on.
    case temporarilyUnavailable
}

/// What one sync pass did.
public enum HealthSyncResult: Equatable, Sendable {
    /// The mirror is current with Apple Health as of the stored anchor.
    /// `skipped` counts samples the mirror can't hold (a weight that isn't
    /// positive, or one the adapter couldn't read); they are left out and
    /// the sync carries on.
    case synced(upserted: Int, markedDeleted: Int, skipped: Int)
    /// Apple Health was out of reach. Pages applied before that stay, and
    /// the anchor sits at the last one fully applied, so the next pass
    /// carries on from there.
    case degraded(HealthAccessError)
}
