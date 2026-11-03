// SPDX-License-Identifier: GPL-3.0-or-later
// The phone half of the sync spine (spec §9; the phone is the canonical
// store and the sole HealthKit writer).
//
// - Outbox in: each record is handed to a `WatchOutboxApplying` upsert
//   keyed by the record's stable id, then acked. Every delivery is acked,
//   duplicates included, so the phone keeps no ledger of what it has seen:
//   a retransmission after a lost ack is applied again (a no-op, because
//   the apply is an upsert) and acked again, and the watch prunes it.
// - A failed apply sends no ack. The record stays in the watch outbox and
//   arrives again on the watch's next activation.
// - Digest out: the caller builds the digest (FLPlate's
//   `WatchDigestBuilder`) and publishes it here; the channel keeps only the
//   latest.
import FLCore
import Foundation

/// Applies one watch-created record to the phone's canonical store.
///
/// Must be an idempotent upsert keyed by `item.id` (the shot or meal id, or
/// the hunger edit's own id): the same item can arrive any number of times,
/// before or after an earlier copy was applied, and must leave one row.
/// Throwing withholds the ack, so the watch retries.
@MainActor
public protocol WatchOutboxApplying: AnyObject {
    func upsert(_ item: WatchOutboxItem) throws
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
            try applier.upsert(item)
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
