// SPDX-License-Identifier: GPL-3.0-or-later
// Weight mirror and correction persistence lane (spec §1).
import FLCore
import Foundation
import SwiftData

public enum WeightStoreError: Error, Equatable, Sendable {
    case invalidWeight(Double)
    case invalidCorrection(UUID)
}

/// HealthKit's local weight mirror and append-only corrections.
@MainActor
public protocol WeightStore: AnyObject {
    func upsertWeightSample(_ sample: WeightSampleData) throws
    func markWeightSampleDeletedInHK(hkUUID: UUID) throws
    func weightSamples(includingDeletedInHK: Bool) throws -> [WeightSampleData]
    func addCorrection(_ correction: CorrectionData) throws
    func corrections(targetKind: CorrectionTargetKind?) throws -> [CorrectionData]
    func deleteCorrection(id: UUID) throws
    func correctedWeightView() throws -> [CorrectedWeightSample]
}

extension SwiftDataStore: WeightStore {
    public func upsertWeightSample(_ sample: WeightSampleData) throws {
        try validate(sample.weightKg)
        let mirrors = try context.fetch(FetchDescriptor<WeightSampleMirror>())
        if let stored = mirrors.first(where: { $0.hkUUID == sample.hkUUID }) {
            stored.measuredAt = sample.measuredAt
            stored.weightKg = sample.weightKg
            stored.sourceBundleID = sample.sourceBundleID
            stored.deletedInHK = sample.deletedInHK
        } else {
            context.insert(
                WeightSampleMirror(
                    hkUUID: sample.hkUUID,
                    measuredAt: sample.measuredAt,
                    weightKg: sample.weightKg,
                    sourceBundleID: sample.sourceBundleID,
                    deletedInHK: sample.deletedInHK
                )
            )
        }
        try commit()
    }

    public func markWeightSampleDeletedInHK(hkUUID: UUID) throws {
        let mirrors = try context.fetch(FetchDescriptor<WeightSampleMirror>())
        guard let stored = mirrors.first(where: { $0.hkUUID == hkUUID }) else {
            throw FreeLunchStoreError.notFound(hkUUID)
        }
        stored.deletedInHK = true
        try commit()
    }

    public func weightSamples(includingDeletedInHK: Bool) throws -> [WeightSampleData] {
        try context.fetch(FetchDescriptor<WeightSampleMirror>())
            .filter { includingDeletedInHK || !$0.deletedInHK }
            .map { try $0.asWeightSampleData() }
            .sorted(by: WeightSampleData.displayOrder)
    }

    public func addCorrection(_ correction: CorrectionData) throws {
        guard try !context.fetch(FetchDescriptor<Correction>()).contains(where: { $0.id == correction.id }) else {
            throw FreeLunchStoreError.duplicateID(correction.id)
        }
        try validate(correction)
        context.insert(
            Correction(
                id: correction.id,
                createdAt: correction.createdAt,
                targetKind: correction.targetKind,
                targetID: correction.targetID,
                action: correction.action,
                replacement: correction.replacement,
                reason: correction.reason
            )
        )
        try commit()
    }

    public func corrections(targetKind: CorrectionTargetKind?) throws -> [CorrectionData] {
        try context.fetch(FetchDescriptor<Correction>())
            .filter { targetKind == nil || $0.targetKind == targetKind }
            .map { $0.asCorrectionData() }
            .sorted(by: CorrectionData.creationOrder)
    }

    public func deleteCorrection(id: UUID) throws {
        let rows = try context.fetch(FetchDescriptor<Correction>())
        guard let stored = rows.first(where: { $0.id == id }) else {
            throw FreeLunchStoreError.notFound(id)
        }
        context.delete(stored)
        try commit()
    }

    public func correctedWeightView() throws -> [CorrectedWeightSample] {
        CorrectedWeightView.derive(
            samples: try weightSamples(includingDeletedInHK: true),
            corrections: try corrections(targetKind: .hkWeightSample)
        )
    }

    private func validate(_ weightKg: Double) throws {
        guard weightKg.isFinite, weightKg >= 0 else {
            throw WeightStoreError.invalidWeight(weightKg)
        }
    }

    private func validate(_ correction: CorrectionData) throws {
        switch correction.action {
        case .exclude:
            guard correction.replacement == nil else {
                throw WeightStoreError.invalidCorrection(correction.id)
            }
        case .replace:
            guard let data = correction.replacement else {
                throw WeightStoreError.invalidCorrection(correction.id)
            }
            guard correction.targetKind == .hkWeightSample else { return }
            guard
                let replacement = try? WeightSampleReplacement.decode(data),
                replacement.weightKg.isFinite,
                replacement.weightKg > 0
            else {
                throw WeightStoreError.invalidCorrection(correction.id)
            }
        }
    }
}

fileprivate extension WeightSampleMirror {
    func asWeightSampleData() throws -> WeightSampleData {
        guard weightKg.isFinite, weightKg >= 0 else {
            throw WeightStoreError.invalidWeight(weightKg)
        }
        return WeightSampleData(
            hkUUID: hkUUID,
            measuredAt: measuredAt,
            weight: Kilograms(weightKg),
            sourceBundleID: sourceBundleID,
            deletedInHK: deletedInHK
        )
    }
}

fileprivate extension Correction {
    func asCorrectionData() -> CorrectionData {
        CorrectionData(
            id: id,
            createdAt: createdAt,
            targetKind: targetKind,
            targetID: targetID,
            action: action,
            replacement: replacement,
            reason: reason
        )
    }
}

fileprivate extension WeightSampleData {
    static func displayOrder(_ lhs: WeightSampleData, _ rhs: WeightSampleData) -> Bool {
        if lhs.measuredAt != rhs.measuredAt { return lhs.measuredAt < rhs.measuredAt }
        return lhs.hkUUID.uuidString < rhs.hkUUID.uuidString
    }
}

fileprivate extension CorrectionData {
    static func creationOrder(_ lhs: CorrectionData, _ rhs: CorrectionData) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
