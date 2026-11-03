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
    /// One mirror row by its HealthKit UUID, flagged or not; nil if absent.
    func weightSample(hkUUID: UUID) throws -> WeightSampleData?
    func addCorrection(_ correction: CorrectionData) throws
    func corrections(targetKind: CorrectionTargetKind?) throws -> [CorrectionData]
    func deleteCorrection(id: UUID) throws
    func correctedWeightView() throws -> [CorrectedWeightSample]
}

extension SwiftDataStore: WeightStore {
    public func upsertWeightSample(_ sample: WeightSampleData) throws {
        try requireStoreKind(.phone, operation: "upsertWeightSample")
        try validate(sample.weightKg)
        if let stored = try weightMirror(hkUUID: sample.hkUUID) {
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
        try requireStoreKind(.phone, operation: "markWeightSampleDeletedInHK")
        guard let stored = try weightMirror(hkUUID: hkUUID) else {
            throw FreeLunchStoreError.notFound(hkUUID)
        }
        stored.deletedInHK = true
        try commit()
    }

    public func weightSamples(includingDeletedInHK: Bool) throws -> [WeightSampleData] {
        try requireStoreKind(.phone, operation: "weightSamples")
        return try context.fetch(FetchDescriptor<WeightSampleMirror>())
            .filter { includingDeletedInHK || !$0.deletedInHK }
            .map { try $0.asWeightSampleData() }
            .sorted(by: WeightSampleData.displayOrder)
    }

    public func weightSample(hkUUID: UUID) throws -> WeightSampleData? {
        try requireStoreKind(.phone, operation: "weightSample")
        return try weightMirror(hkUUID: hkUUID)?.asWeightSampleData()
    }

    public func addCorrection(_ correction: CorrectionData) throws {
        try requireStoreKind(.phone, operation: "addCorrection")
        guard try model(Correction.self, id: correction.id) == nil else {
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
        try requireStoreKind(.phone, operation: "corrections")
        return try context.fetch(FetchDescriptor<Correction>())
            .filter { targetKind == nil || $0.targetKind == targetKind }
            .map { $0.asCorrectionData() }
            .sorted(by: CorrectionData.creationOrder)
    }

    public func deleteCorrection(id: UUID) throws {
        try requireStoreKind(.phone, operation: "deleteCorrection")
        guard let stored = try model(Correction.self, id: id) else {
            throw FreeLunchStoreError.notFound(id)
        }
        context.delete(stored)
        try commit()
    }

    public func correctedWeightView() throws -> [CorrectedWeightSample] {
        try requireStoreKind(.phone, operation: "correctedWeightView")
        return CorrectedWeightView.derive(
            samples: try weightSamples(includingDeletedInHK: true),
            corrections: try corrections(targetKind: .hkWeightSample)
        )
    }

    private func validate(_ weightKg: Double) throws {
        guard weightKg.isFinite, weightKg > 0 else {
            throw WeightStoreError.invalidWeight(weightKg)
        }
    }

    private func weightMirror(hkUUID: UUID) throws -> WeightSampleMirror? {
        var descriptor = FetchDescriptor<WeightSampleMirror>(predicate: #Predicate { $0.hkUUID == hkUUID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
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

extension Correction: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<Correction> { #Predicate { $0.id == id } }
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
