// SPDX-License-Identifier: GPL-3.0-or-later
// The WatchConnectivity transport for the sync spine, on iOS and watchOS.
//
// Deliberately thin: it maps `send` to user info transfers (ordered,
// queued by the system across relaunches), `publishDigest` to the
// application context (latest-wins, retained as `receivedApplicationContext`)
// and decodes inbound payloads for the receiver. Every protocol rule lives in
// the coordinators, which the host-run tests cover over
// `InMemoryWatchSyncLink`; the package's macOS test host has no
// WatchConnectivity, so this file compiles only in the app builds.
//
// Delegate callbacks arrive on a system queue. Each one copies out the
// Sendable bytes it needs, then hops to the main actor, where the stores
// live.
#if canImport(WatchConnectivity)
import FLCore
import Foundation
@preconcurrency import WatchConnectivity

@MainActor
public final class WCSessionWatchSyncTransport: NSObject, WatchSyncTransport {
    public weak var receiver: (any WatchSyncReceiving)?

    /// Runs on the main actor after each successful activation: the watch
    /// side's retry moment (`WatchSyncCoordinator.activate()`).
    public var onActivated: (@MainActor () -> Void)?

    /// The last inbound payload that failed to decode or apply. A failed
    /// apply sends no ack, so the sender retries; this is for diagnostics.
    public private(set) var lastReceiveError: (any Error)?

    private let session: WCSession

    public init(session: WCSession = .default) {
        self.session = session
        super.init()
    }

    public static var isSupported: Bool { WCSession.isSupported() }

    public func activate() {
        session.delegate = self
        session.activate()
    }

    public func send(_ message: WatchSyncMessage) throws {
        var userInfo: [String: Any] = [Keys.message: try WatchSyncCodec.encode(message)]
        if case let .outbox(item) = message {
            userInfo[Keys.outboxID] = item.id.uuidString
        }
        session.transferUserInfo(userInfo)
    }

    public func publishDigest(_ digest: WatchDigestData) throws {
        try session.updateApplicationContext([Keys.digest: try WatchSyncCodec.encode(digest)])
    }

    public var receivedDigest: WatchDigestData? {
        (session.receivedApplicationContext[Keys.digest] as? Data)
            .flatMap { try? WatchSyncCodec.decodeDigest($0) }
    }

    public var queuedOutboxIDs: Set<UUID> {
        Set(session.outstandingUserInfoTransfers.compactMap { transfer in
            (transfer.userInfo[Keys.outboxID] as? String).flatMap(UUID.init(uuidString:))
        })
    }

    fileprivate func deliver(message data: Data) {
        do {
            try receiver?.receive(WatchSyncCodec.decodeMessage(data))
        } catch {
            lastReceiveError = error
        }
    }

    fileprivate func deliver(digest data: Data) {
        do {
            try receiver?.receive(digest: WatchSyncCodec.decodeDigest(data))
        } catch {
            lastReceiveError = error
        }
    }

    fileprivate enum Keys {
        static let message = "fl.sync.message"
        static let outboxID = "fl.sync.outboxID"
        static let digest = "fl.sync.digest"
    }
}

extension WCSessionWatchSyncTransport: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor [weak self] in
            self?.onActivated?()
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[Keys.message] as? Data else { return }
        Task { @MainActor [weak self] in
            self?.deliver(message: data)
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[Keys.digest] as? Data else { return }
        Task { @MainActor [weak self] in
            self?.deliver(digest: data)
        }
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        // A watch switch: reactivate so the new watch is served.
        session.activate()
    }
    #endif
}
#endif
