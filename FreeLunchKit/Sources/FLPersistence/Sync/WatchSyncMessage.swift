// SPDX-License-Identifier: GPL-3.0-or-later
// The phone ↔ watch wire (spec §9 sync, §1 store shape).
//
// Three channels, after the inherited Burly spine:
//
// - **Digest down** (phone → watch, latest-wins): `WatchDigestData`. Only
//   the newest value matters, so a lost or superseded digest is never
//   retried; the next publish replaces it.
// - **Outbox up** (watch → phone, queued in order): one message per
//   watch-created record, retransmitted verbatim until acknowledged.
// - **Acks down** (phone → watch, queued in order): the outbox ids the
//   phone has durably applied. An ack is the only thing that prunes the
//   watch outbox; a transport's "transfer finished" never does, because it
//   proves the bytes left the device, not that the phone kept them.
//
// Every payload travels inside a versioned envelope so a newer peer's
// message is refused rather than misread.
import FLCore
import Foundation

public enum WatchSyncMessage: Sendable, Hashable, Codable {
    /// Watch → phone: one outbox record, keyed by its stable `id`.
    case outbox(WatchOutboxItem)
    /// Phone → watch: outbox ids the phone has applied.
    case ack([UUID])
}

public enum WatchSyncCodecError: Error, Equatable, Sendable {
    /// The envelope's format is newer than this build understands; the
    /// message is held for an app update, never guessed at.
    case unsupportedFormat(Int)
}

/// JSON in a versioned envelope, for both the queued messages and the
/// digest.
public enum WatchSyncCodec {
    public static let formatVersion = 1

    public static func encode(_ message: WatchSyncMessage) throws -> Data {
        try encodeEnvelope(message)
    }

    public static func decodeMessage(_ data: Data) throws -> WatchSyncMessage {
        try decodeEnvelope(data)
    }

    public static func encode(_ digest: WatchDigestData) throws -> Data {
        try encodeEnvelope(digest)
    }

    public static func decodeDigest(_ data: Data) throws -> WatchDigestData {
        try decodeEnvelope(data)
    }

    private struct Envelope<Body: Codable>: Codable {
        let format: Int
        let body: Body
    }

    private struct Header: Decodable {
        let format: Int
    }

    private static func encodeEnvelope<Body: Codable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(format: formatVersion, body: body))
    }

    private static func decodeEnvelope<Body: Codable>(_ data: Data) throws -> Body {
        let decoder = JSONDecoder()
        let format = try decoder.decode(Header.self, from: data).format
        guard format <= formatVersion else {
            throw WatchSyncCodecError.unsupportedFormat(format)
        }
        return try decoder.decode(Envelope<Body>.self, from: data).body
    }
}
