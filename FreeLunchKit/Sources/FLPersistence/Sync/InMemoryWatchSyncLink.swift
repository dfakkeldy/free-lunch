// SPDX-License-Identifier: GPL-3.0-or-later
// A deterministic, in-process phone ↔ watch link: the fake transport every
// sync test runs over, and usable for previews and UI-test launches.
//
// It models WatchConnectivity's channel semantics rather than one generic
// queue:
// - each direction has an ordered queue (user info transfers) that keeps
//   its messages across a relaunch of either side;
// - each direction has a latest-wins digest slot (application context);
//   once delivered, the receiver's copy is retained as `receivedDigest`.
//
// Nothing moves until a test says so (`deliverNext`, `deliverDigest`,
// `pump`), and faults are explicit: drop the next messages, deliver one
// twice (the copy arrives last, after everything queued behind it), or
// lose everything in flight. Every payload is encoded and decoded through
// `WatchSyncCodec`, so the wire format is exercised too.
import FLCore
import Foundation

@MainActor
public final class InMemoryWatchSyncLink {
    public enum Side: Sendable, Hashable {
        case phone
        case watch

        var other: Side { self == .phone ? .watch : .phone }
    }

    /// One device's end of the link.
    @MainActor
    public final class Endpoint: WatchSyncTransport {
        public let side: Side
        public weak var receiver: (any WatchSyncReceiving)?
        fileprivate weak var link: InMemoryWatchSyncLink?
        fileprivate var deliveredDigest: Data?

        fileprivate init(side: Side) {
            self.side = side
        }

        public func send(_ message: WatchSyncMessage) throws {
            try requireLink().enqueue(message, from: side)
        }

        public func publishDigest(_ digest: WatchDigestData) throws {
            try requireLink().publish(digest, from: side)
        }

        public var receivedDigest: WatchDigestData? {
            deliveredDigest.flatMap { try? WatchSyncCodec.decodeDigest($0) }
        }

        public var queuedOutboxIDs: Set<UUID> {
            link?.queuedOutboxIDs(from: side) ?? []
        }

        private func requireLink() throws -> InMemoryWatchSyncLink {
            guard let link else { throw InMemoryWatchSyncLinkError.linkReleased }
            return link
        }
    }

    private struct Queued {
        let data: Data
        let outboxID: UUID?
    }

    public let phone: Endpoint
    public let watch: Endpoint

    /// Errors thrown by a receiver, in delivery order. The message that
    /// caused each one was consumed, as the real transport would have.
    public private(set) var receiveErrors: [any Error] = []

    private var queues: [Side: [Queued]] = [.phone: [], .watch: []]
    private var pendingDigest: [Side: Data] = [:]
    private var dropsPending: [Side: Int] = [.phone: 0, .watch: 0]
    private var duplicatesPending: [Side: Int] = [.phone: 0, .watch: 0]

    public init() {
        phone = Endpoint(side: .phone)
        watch = Endpoint(side: .watch)
        phone.link = self
        watch.link = self
    }

    // MARK: Inspection

    /// Messages queued for delivery *to* `side`.
    public func queuedCount(to side: Side) -> Int {
        queues[side, default: []].count
    }

    // MARK: Faults

    /// The next `count` messages bound for `side` are consumed undelivered.
    public func dropNext(to side: Side, count: Int = 1) {
        dropsPending[side, default: 0] += count
    }

    /// The next `count` messages bound for `side` are delivered now and
    /// again after everything currently queued behind them.
    public func duplicateNext(to side: Side, count: Int = 1) {
        duplicatesPending[side, default: 0] += count
    }

    /// Everything in flight toward `side` (or both sides) vanishes: a
    /// transfer killed midway.
    public func loseInFlight(to side: Side? = nil) {
        for target in side.map({ [$0] }) ?? [.phone, .watch] {
            queues[target] = []
            pendingDigest[target] = nil
        }
    }

    // MARK: Delivery

    /// Delivers the pending digest to `side`, if any. Returns whether one
    /// was delivered.
    @discardableResult
    public func deliverDigest(to side: Side) -> Bool {
        guard let data = pendingDigest[side] else { return false }
        let target = endpoint(side)
        pendingDigest[side] = nil
        target.deliveredDigest = data
        guard let receiver = target.receiver else { return true }
        do {
            try receiver.receive(digest: WatchSyncCodec.decodeDigest(data))
        } catch {
            receiveErrors.append(error)
        }
        return true
    }

    /// Delivers (or drops) the oldest message queued to `side`. Returns
    /// false when nothing is queued or no receiver is running there, in
    /// which case the message waits, as it would for a closed app.
    @discardableResult
    public func deliverNext(to side: Side) -> Bool {
        guard var queue = queues[side], let next = queue.first else { return false }
        if dropsPending[side, default: 0] > 0 {
            dropsPending[side, default: 0] -= 1
            queue.removeFirst()
            queues[side] = queue
            return true
        }
        guard let receiver = endpoint(side).receiver else { return false }
        queue.removeFirst()
        if duplicatesPending[side, default: 0] > 0 {
            duplicatesPending[side, default: 0] -= 1
            queue.append(next)
        }
        queues[side] = queue
        do {
            try receiver.receive(WatchSyncCodec.decodeMessage(next.data))
        } catch {
            receiveErrors.append(error)
        }
        return true
    }

    /// Delivers digests and messages both ways until nothing more moves.
    /// Returns the number of deliveries (drops included).
    @discardableResult
    public func pump() -> Int {
        var moved = 0
        while true {
            if deliverDigest(to: .watch) || deliverDigest(to: .phone)
                || deliverNext(to: .phone) || deliverNext(to: .watch) {
                moved += 1
            } else {
                return moved
            }
        }
    }

    // MARK: Endpoint plumbing

    private func endpoint(_ side: Side) -> Endpoint {
        side == .phone ? phone : watch
    }

    fileprivate func enqueue(_ message: WatchSyncMessage, from side: Side) throws {
        let outboxID: UUID?
        if case let .outbox(item) = message {
            outboxID = item.id
        } else {
            outboxID = nil
        }
        queues[side.other, default: []].append(Queued(data: try WatchSyncCodec.encode(message), outboxID: outboxID))
    }

    fileprivate func publish(_ digest: WatchDigestData, from side: Side) throws {
        pendingDigest[side.other] = try WatchSyncCodec.encode(digest)
    }

    fileprivate func queuedOutboxIDs(from side: Side) -> Set<UUID> {
        Set(queues[side.other, default: []].compactMap(\.outboxID))
    }
}

public enum InMemoryWatchSyncLinkError: Error, Equatable, Sendable {
    /// The endpoint outlived its link.
    case linkReleased
}
