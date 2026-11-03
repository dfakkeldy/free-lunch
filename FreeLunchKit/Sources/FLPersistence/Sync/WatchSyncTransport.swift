// SPDX-License-Identifier: GPL-3.0-or-later
// The seam between the sync rules and the wire. Production uses the
// WatchConnectivity adapter (WCSessionWatchSyncTransport, iOS and watchOS
// only); every test uses `InMemoryWatchSyncLink`, which models the same
// channel semantics deterministically. The rules live in the coordinators,
// never in a transport, so the host-run tests exercise all of them.
import FLCore
import Foundation

/// One device's end of the link. Main-actor bound like the stores it feeds.
@MainActor
public protocol WatchSyncTransport: AnyObject {
    /// Where inbound traffic goes. A coordinator installs itself; a newer
    /// coordinator (after a relaunch) replaces the older one.
    var receiver: (any WatchSyncReceiving)? { get set }

    /// Queues `message` on the ordered channel (WatchConnectivity's user
    /// info transfers). Delivery may fail, repeat or happen after a
    /// relaunch; the protocol tolerates all three.
    func send(_ message: WatchSyncMessage) throws

    /// Replaces the latest-wins digest (WatchConnectivity's application
    /// context).
    func publishDigest(_ digest: WatchDigestData) throws

    /// The most recent digest this device received, retained by the
    /// transport across relaunches; nil before the first one arrives.
    var receivedDigest: WatchDigestData? { get }

    /// Outbox ids still queued in the transport from this device, so a
    /// retry does not queue the same record twice. Empty when the
    /// transport cannot say; a duplicate is harmless either way.
    var queuedOutboxIDs: Set<UUID> { get }
}

/// Inbound traffic, already decoded. Throwing means "not applied": the
/// sender's retry delivers it again.
@MainActor
public protocol WatchSyncReceiving: AnyObject {
    func receive(_ message: WatchSyncMessage) throws
    func receive(digest: WatchDigestData) throws
}
