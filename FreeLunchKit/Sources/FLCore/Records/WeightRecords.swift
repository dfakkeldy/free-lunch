// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — HealthKit weight mirror values and immutable correction derivation
// (spec §1).
import Foundation

/// A locally cached HealthKit weight sample. HealthKit remains canonical.
public struct WeightSampleData: Sendable, Hashable, Identifiable {
    public let hkUUID: UUID
    public var measuredAt: Date
    /// Canonical kilograms.
    public private(set) var weightKg: Double
    public var sourceBundleID: String
    public var deletedInHK: Bool

    public var id: UUID { hkUUID }

    public init(
        hkUUID: UUID,
        measuredAt: Date,
        weight: Kilograms,
        sourceBundleID: String,
        deletedInHK: Bool = false
    ) {
        self.hkUUID = hkUUID
        self.measuredAt = measuredAt
        weightKg = weight.value
        self.sourceBundleID = sourceBundleID
        self.deletedInHK = deletedInHK
    }
}

/// The Codable payload for a `.replace` correction of a weight sample.
public struct WeightSampleReplacement: Codable, Sendable, Hashable {
    /// Canonical kilograms. Store validation requires a finite, positive value.
    public let weightKg: Double
    /// `nil` preserves the mirrored sample's timestamp.
    public let measuredAt: Date?

    public init(weight: Kilograms, measuredAt: Date? = nil) {
        weightKg = weight.value
        self.measuredAt = measuredAt
    }

    /// Builds the deterministic Codable payload used by a weight correction.
    public static func encode(weight: Kilograms, measuredAt: Date? = nil) throws -> Data {
        try WeightSampleReplacement(weight: weight, measuredAt: measuredAt).encoded()
    }

    /// Encodes an already-constructed replacement with the same stable form.
    public static func encode(_ replacement: WeightSampleReplacement) throws -> Data {
        try replacement.encoded()
    }

    /// Encodes dates as milliseconds since the Unix epoch, not ISO-8601 text.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    /// Decodes the deterministic correction payload.
    public static func decode(_ data: Data) throws -> WeightSampleReplacement {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return try decoder.decode(WeightSampleReplacement.self, from: data)
    }
}

/// An immutable correction of an imported or HealthKit-sourced record.
public struct CorrectionData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let targetKind: CorrectionTargetKind
    public let targetID: String
    public let action: CorrectionAction
    public let replacement: Data?
    public let reason: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        targetKind: CorrectionTargetKind,
        targetID: String,
        action: CorrectionAction,
        replacement: Data? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.targetKind = targetKind
        self.targetID = targetID
        self.action = action
        self.replacement = replacement
        self.reason = reason
    }
}

/// One sample in the derived, correction-aware weight view.
public struct CorrectedWeightSample: Sendable, Hashable, Identifiable {
    public let hkUUID: UUID
    public let measuredAt: Date
    /// Canonical kilograms.
    public let weightKg: Double
    public let sourceBundleID: String
    /// The replace correction which supplied this value, if any.
    public let correctionID: UUID?

    public var id: UUID { hkUUID }

    public init(
        hkUUID: UUID,
        measuredAt: Date,
        weightKg: Double,
        sourceBundleID: String,
        correctionID: UUID?
    ) {
        self.hkUUID = hkUUID
        self.measuredAt = measuredAt
        self.weightKg = weightKg
        self.sourceBundleID = sourceBundleID
        self.correctionID = correctionID
    }
}

/// Pure derivation of Free Lunch's correction-aware view of HealthKit weight.
public enum CorrectedWeightView {
    public static func derive(
        samples: [WeightSampleData],
        corrections: [CorrectionData]
    ) -> [CorrectedWeightSample] {
        let relevant = corrections.filter { $0.targetKind == .hkWeightSample }

        let view = samples.compactMap { sample -> CorrectedWeightSample? in
            guard !sample.deletedInHK else { return nil }
            // Each candidate carries its decoded replacement so it is decoded once.
            let candidates = relevant.compactMap { correction -> (CorrectionData, WeightSampleReplacement?)? in
                guard UUID(uuidString: correction.targetID) == sample.hkUUID else { return nil }
                switch correction.action {
                case .exclude:
                    return (correction, nil)
                case .replace:
                    guard let replacement = validReplacement(correction) else { return nil }
                    return (correction, replacement)
                }
            }
            guard let (correction, replacement) = candidates.max(by: { isOlder($0.0, $1.0) }) else {
                return CorrectedWeightSample(
                    hkUUID: sample.hkUUID,
                    measuredAt: sample.measuredAt,
                    weightKg: sample.weightKg,
                    sourceBundleID: sample.sourceBundleID,
                    correctionID: nil
                )
            }
            guard let replacement else { return nil }  // newest applicable action is .exclude
            return CorrectedWeightSample(
                hkUUID: sample.hkUUID,
                measuredAt: replacement.measuredAt ?? sample.measuredAt,
                weightKg: replacement.weightKg,
                sourceBundleID: sample.sourceBundleID,
                correctionID: correction.id
            )
        }

        return view.sorted { lhs, rhs in
            if lhs.measuredAt != rhs.measuredAt { return lhs.measuredAt < rhs.measuredAt }
            return lhs.hkUUID.uuidString < rhs.hkUUID.uuidString
        }
    }

    private static func isOlder(_ lhs: CorrectionData, _ rhs: CorrectionData) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func validReplacement(_ correction: CorrectionData) -> WeightSampleReplacement? {
        guard
            let data = correction.replacement,
            let replacement = try? WeightSampleReplacement.decode(data),
            replacement.weightKg.isFinite,
            replacement.weightKg > 0
        else {
            return nil
        }
        return replacement
    }
}
