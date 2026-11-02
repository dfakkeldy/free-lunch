// SPDX-License-Identifier: GPL-3.0-or-later
// Weight-lane models (spec §1 WeightSampleMirror, Correction).
//
// HealthKit is canonical for weight; the mirror is a local cache. Imported
// and HealthKit-sourced records never mutate; Correction rows append and the
// corrected view is derived. The store API for these lands separately.
import FLCore
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class WeightSampleMirror {
        @Attribute(.unique) var hkUUID: UUID
        var measuredAt: Date
        /// Canonical kilograms.
        var weightKg: Double
        var sourceBundleID: String
        var deletedInHK: Bool

        init(hkUUID: UUID, measuredAt: Date, weightKg: Double, sourceBundleID: String, deletedInHK: Bool) {
            self.hkUUID = hkUUID
            self.measuredAt = measuredAt
            self.weightKg = weightKg
            self.sourceBundleID = sourceBundleID
            self.deletedInHK = deletedInHK
        }
    }

    @Model
    final class Correction {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var targetKind: CorrectionTargetKind
        /// HealthKit UUID or entity UUID, as a string.
        var targetID: String
        var action: CorrectionAction
        /// Codable replacement payload for `.replace`.
        var replacement: Data?
        var reason: String?

        init(
            id: UUID,
            createdAt: Date,
            targetKind: CorrectionTargetKind,
            targetID: String,
            action: CorrectionAction,
            replacement: Data?,
            reason: String?
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
}
