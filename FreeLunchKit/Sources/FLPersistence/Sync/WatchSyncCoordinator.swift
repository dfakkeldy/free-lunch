// SPDX-License-Identifier: GPL-3.0-or-later
// The watch half of the sync spine (spec §9; the watch's working set §1).
//
// - Outbox up: every record in the persisted outbox is (re)sent on each
//   activation, oldest first, until the phone acks it. The outbox lives in
//   the store, so a force-quit or relaunch loses nothing; the coordinator
//   itself holds no state that a rebuild cannot recover.
// - Prune on ack only: an ack removes exactly the named records. Acks for
//   records already pruned (a duplicate, or a re-ack after a retry) are
//   no-ops.
// - Outbox records are immutable once queued. An ack names an id, not a
//   version, and a record already handed to the transport cannot be
//   recalled, so a later change to it (a coalesced append, an undo) must
//   be a new record with its own id. Editing a queued record in place
//   would let the ack for the old copy prune the new one.
// - Digest down: the newest digest replaces the RecentFoodSnapshot rows
//   (the store caps them at 200 in the phone's order) and becomes the
//   in-memory next-dose and today-remaining glance. An older digest than
//   the one shown, or the same one again, is ignored. On activation the
//   transport's retained digest is re-applied, which is how the glance
//   survives a relaunch.
import FLCore
import Foundation

@MainActor
public final class WatchSyncCoordinator: WatchSyncReceiving {
    private let store: any WatchWorkingSetStore
    private let transport: any WatchSyncTransport

    /// The digest the watch is showing, or nil before the first one.
    public private(set) var digest: WatchDigestData?

    public init(store: any WatchWorkingSetStore, transport: any WatchSyncTransport) {
        self.store = store
        self.transport = transport
        transport.receiver = self
    }

    /// The retry moment: app launch, WatchConnectivity activation, return
    /// to foreground. Applies the retained digest, then resends the outbox.
    /// The two are independent: a failed digest apply still resends, and
    /// its error is rethrown afterwards.
    public func activate() throws {
        var digestError: (any Error)?
        if let retained = transport.receivedDigest {
            do {
                try receive(digest: retained)
            } catch {
                digestError = error
            }
        }
        try sendOutbox()
        if let digestError { throw digestError }
    }

    /// Sends every unacknowledged record not already queued in the
    /// transport, in queue order. Call after enqueuing a new record.
    public func sendOutbox() throws {
        let queued = transport.queuedOutboxIDs
        for item in try store.outbox() where !queued.contains(item.id) {
            try transport.send(.outbox(item))
        }
    }

    /// Undelivered records, for the root screen's pending count (spec §9).
    public func pendingCount() throws -> Int {
        try store.outbox().count
    }

    public func receive(_ message: WatchSyncMessage) throws {
        switch message {
        case let .ack(ids):
            try store.acknowledge(ids)
        case .outbox:
            // Phone-bound; a watch never applies another device's outbox.
            break
        }
    }

    public func receive(digest incoming: WatchDigestData) throws {
        if let digest, incoming.generatedAt < digest.generatedAt || incoming == digest { return }
        try store.replaceRecentFoods(incoming.recentFoods)
        digest = incoming
    }
}
