// SPDX-License-Identifier: GPL-3.0-or-later
// The phone half of the sync spine (spec §9; the phone is the canonical
// store and the sole HealthKit writer).
//
// - Outbox in: each record is handed to `WatchOutboxApplying`, then acked.
//   Every delivery is acked, duplicates included, so the coordinator keeps
//   no ledger of what it has seen: a retransmission is handed over again
//   and acked again, and the watch prunes it. Retransmissions are routine,
//   not a rare fault: a relaunched watch resends its outbox on activation,
//   before it reads an ack that is still waiting, so a copy can arrive
//   long after the phone applied the first one and the user edited it.
// - A failed apply sends no ack. The record stays in the watch outbox and
//   arrives again on the watch's next activation.
// - Digest out: the caller builds the digest (FLPlate's
//   `WatchDigestBuilder`) and publishes it here; the channel keeps only the
//   latest.
import FLCore
import Foundation

/// Applies one watch-created record to the phone's canonical store.
///
/// The same item can arrive any number of times, before or after an earlier
/// copy was applied and after the phone has since edited the row, so the
/// first copy wins:
/// - A shot or meal inserts only when no row with `item.id` exists; when one
///   does, the apply is a no-op. A later copy never overwrites a phone-side
///   edit. (A row the phone has since deleted is not covered: with no record
///   of the deletion, a late copy inserts it again. Closing that needs a
///   stored tombstone or applied-id set, which this layer does not keep.)
/// - Hunger edits share their meal's `subjectID`, each with its own `id`.
///   An older edit can arrive after a newer one (a lost transfer resent
///   later, or a duplicate), so the apply keeps the latest `editedAt` per
///   meal. MealEntry stores no edit time for its hunger value, so the
///   applier needs one stored alongside it to honour this.
///
/// Throwing withholds the ack, so the watch retries.
@MainActor
public protocol WatchOutboxApplying: AnyObject {
    func apply(_ item: WatchOutboxItem) throws
}

@MainActor
public final class PhoneSyncCoordinator: WatchSyncReceiving {
    private let transport: any WatchSyncTransport
    private let applier: any WatchOutboxApplying

    public init(transport: any WatchSyncTransport, applier: any WatchOutboxApplying) {
        self.transport = transport
        self.applier = applier
        transport.receiver = self
    }

    /// Publishes `digest` as the watch's current digest.
    public func publish(_ digest: WatchDigestData) throws {
        try transport.publishDigest(digest)
    }

    public func receive(_ message: WatchSyncMessage) throws {
        switch message {
        case let .outbox(item):
            try applier.apply(item)
            try transport.send(.ack([item.id]))
        case .ack:
            // Watch-bound; the phone has no outbox to prune.
            break
        }
    }

    public func receive(digest: WatchDigestData) throws {
        // Watch-bound; the phone is the digest's source.
    }
}
