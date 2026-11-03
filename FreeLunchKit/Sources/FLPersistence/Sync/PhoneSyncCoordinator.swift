// SPDX-License-Identifier: GPL-3.0-or-later
// The phone half of the sync spine (spec §9; the phone is the canonical
// store and the sole HealthKit writer).
//
// - Outbox in, ledger first: an item whose id is already in the
//   `AppliedOutboxLedger` is acked without reaching the applier. Otherwise
//   the item is applied, its id recorded, and only then acked.
//   Retransmissions are routine, not a rare fault: a relaunched watch
//   resends its outbox on activation, before it reads an ack that is still
//   waiting, so a copy can arrive long after the phone applied the first
//   one and the user edited or deleted it. The ledger is what keeps such a
//   copy from bringing a deleted record back.
// - Every delivery is acked once it is known to be applied, duplicates
//   included, so the watch prunes it.
// - A failed apply, or a failed record after a successful apply, sends no
//   ack. The record stays in the watch outbox and arrives again on the
//   watch's next activation. After a failed record that copy reaches the
//   applier a second time. Its insert-if-absent rule keeps a phone edit
//   made in between, but a phone delete made in between is undone: the
//   copy finds no row and inserts it again. Apply and record are two
//   saves, so a crash or failed save between them is the one path that
//   still reopens. Closing it needs both in one save, which the store API
//   does not offer yet.
// - Digest out: the caller builds the digest (FLPlate's
//   `WatchDigestBuilder`) and publishes it here; the channel keeps only the
//   latest.
import FLCore
import Foundation

/// Applies one watch-created record to the phone's canonical store.
///
/// `PhoneSyncCoordinator` consults its `AppliedOutboxLedger` first, so an
/// item normally reaches the applier once. It can still arrive twice: when
/// the apply succeeded but recording its id failed (or the app died in
/// between), the watch resends it and the next copy is applied again. So
/// the first copy wins here too:
/// - A shot or meal inserts only when no row with `item.id` exists; when one
///   does, the apply is a no-op. A replay never overwrites a phone-side
///   edit. A row the phone deleted after the id was recorded is covered by
///   the ledger, not by this rule. A row deleted after the apply but before
///   the id was recorded is not covered by either: the replay inserts it
///   again.
/// - Hunger edits share their meal's `subjectID`, each with its own `id`.
///   An older edit can arrive after a newer one (a lost transfer resent
///   later), so the apply keeps the latest `editedAt` per meal. MealEntry
///   stores no edit time for its hunger value, so the applier needs one
///   stored alongside it to honour this.
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
    private let ledger: any AppliedOutboxLedger
    private let now: () -> Date

    /// `ledger` is the phone store in production. `now` stamps each ledger
    /// row's `appliedAt`.
    public init(
        transport: any WatchSyncTransport,
        applier: any WatchOutboxApplying,
        ledger: any AppliedOutboxLedger,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.applier = applier
        self.ledger = ledger
        self.now = now
        transport.receiver = self
    }

    /// Publishes `digest` as the watch's current digest.
    public func publish(_ digest: WatchDigestData) throws {
        try transport.publishDigest(digest)
    }

    public func receive(_ message: WatchSyncMessage) throws {
        switch message {
        case let .outbox(item):
            if try !ledger.hasAppliedOutboxItem(id: item.id) {
                try applier.apply(item)
                try ledger.recordAppliedOutboxItem(id: item.id, appliedAt: now())
            }
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
