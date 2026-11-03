// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's applied-id ledger for the sync spine (spec §9): which watch
// outbox items it has already applied. `PhoneSyncCoordinator` checks it
// before handing a delivery to the applier, so a late retransmission is
// acked without being applied again, and a record the phone has since
// deleted stays deleted.
import Foundation
import SwiftData

/// A durable set of applied `WatchOutboxItem.id`s. Phone store only.
///
/// Entries are kept indefinitely, one small row per applied outbox item,
/// with no pruning. Shots and meals reuse their record's id as the outbox
/// id, so that is one row each; every hunger edit has its own id and row. A retransmission can arrive after any delay (a watch
/// left off for weeks still holds its unacked outbox), so there is no age
/// after which an id is safe to forget.
@MainActor
public protocol AppliedOutboxLedger: AnyObject {
    /// Whether the item with this acknowledgement id has been applied.
    func hasAppliedOutboxItem(id: UUID) throws -> Bool
    /// Records the item as applied, durably, before this returns. Recording
    /// an id already in the ledger is a no-op that keeps the first
    /// `appliedAt`.
    func recordAppliedOutboxItem(id: UUID, appliedAt: Date) throws
}

extension SwiftDataStore: AppliedOutboxLedger {
    public func hasAppliedOutboxItem(id: UUID) throws -> Bool {
        try requireStoreKind(.phone, operation: "hasAppliedOutboxItem")
        return try appliedOutboxRecord(id: id) != nil
    }

    public func recordAppliedOutboxItem(id: UUID, appliedAt: Date) throws {
        try requireStoreKind(.phone, operation: "recordAppliedOutboxItem")
        guard try appliedOutboxRecord(id: id) == nil else { return }
        context.insert(AppliedOutboxRecord(id: id, appliedAt: appliedAt))
        try commit()
    }

    private func appliedOutboxRecord(id: UUID) throws -> AppliedOutboxRecord? {
        var descriptor = FetchDescriptor<AppliedOutboxRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
