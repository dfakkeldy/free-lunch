// SPDX-License-Identifier: GPL-3.0-or-later
// Provider boundary for spec §2 AI photo capture. Live providers live elsewhere.
import Foundation
import FLCore

public struct AICaptureRequest: Sendable, Hashable {
    public let kind: PhotoKind
    public let photoID: UUID?
    public let hint: String?
    public let corrections: [String]

    public init(kind: PhotoKind, photoID: UUID?, hint: String?, corrections: [String]) {
        self.kind = kind
        self.photoID = photoID
        self.hint = hint
        self.corrections = corrections
    }
}

public protocol AICaptureProvider: Sendable {
    var tier: Int { get }
    var modelID: String { get }
    func estimate(_ request: AICaptureRequest) async throws -> Data
}

public enum AICaptureProviderError: Error, Equatable, Sendable {
    case offline
    case failed
}
