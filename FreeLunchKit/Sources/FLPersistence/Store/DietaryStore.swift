// SPDX-License-Identifier: GPL-3.0-or-later
// Dietary mirror persistence lane (spec §1 amendment; semantics §10).
//
// The anchored HealthKit queries that feed this mirror land separately; this
// file is only the local cache they write to and the reads §10 builds on.
import FLCore
import Foundation
import SwiftData

public enum DietaryStoreError: Error, Equatable, Sendable {
    /// A stored row holds a non-finite or negative quantity.
    case invalidStoredSample(UUID)
}

/// HealthKit's local dietary mirror. Phone store only.
@MainActor
public protocol DietaryStore: AnyObject {
    /// Inserts the sample, or overwrites the stored one with the same
    /// `hkUUID`.
    func upsertDietarySample(_ sample: DietarySampleData) throws
    func markDietarySampleDeletedInHK(hkUUID: UUID) throws
    /// Samples dated on the calendar days `first` through `last`
    /// (inclusive), oldest first.
    func dietarySamples(
        from first: Date,
        through last: Date,
        calendar: Calendar,
        includingDeletedInHK: Bool
    ) throws -> [DietarySampleData]
}

extension SwiftDataStore: DietaryStore {
    public func upsertDietarySample(_ sample: DietarySampleData) throws {
        try requireStoreKind(.phone, operation: "upsertDietarySample")
        if let stored = try dietaryMirror(hkUUID: sample.hkUUID) {
            stored.date = sample.date
            stored.kcal = sample.kcal
            stored.proteinG = sample.proteinG
            stored.carbsG = sample.carbsG
            stored.fatG = sample.fatG
            stored.sourceBundleID = sample.sourceBundleID
            stored.deletedInHK = sample.deletedInHK
        } else {
            context.insert(
                DietarySampleMirror(
                    hkUUID: sample.hkUUID,
                    date: sample.date,
                    kcal: sample.kcal,
                    proteinG: sample.proteinG,
                    carbsG: sample.carbsG,
                    fatG: sample.fatG,
                    sourceBundleID: sample.sourceBundleID,
                    deletedInHK: sample.deletedInHK
                )
            )
        }
        try commit()
    }

    public func markDietarySampleDeletedInHK(hkUUID: UUID) throws {
        try requireStoreKind(.phone, operation: "markDietarySampleDeletedInHK")
        guard let stored = try dietaryMirror(hkUUID: hkUUID) else {
            throw FreeLunchStoreError.notFound(hkUUID)
        }
        stored.deletedInHK = true
        try commit()
    }

    /// Day bounds follow `dayIntakes(from:through:calendar:)`: from the start
    /// of `first`'s day up to, not including, the start of the day after
    /// `last`. An inverted range is empty.
    public func dietarySamples(
        from first: Date,
        through last: Date,
        calendar: Calendar,
        includingDeletedInHK: Bool = false
    ) throws -> [DietarySampleData] {
        try requireStoreKind(.phone, operation: "dietarySamples")
        let start = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last)
        guard start <= lastDay,
              let endRaw = calendar.date(byAdding: .day, value: 1, to: lastDay)
        else { return [] }
        let end = calendar.startOfDay(for: endRaw)
        // The mirror holds every dietary sample HealthKit has, so the date
        // bound runs in the store; `date` is non-optional, which keeps the
        // predicate clear of the optional-date sharp edge.
        let descriptor = FetchDescriptor<DietarySampleMirror>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        return try context.fetch(descriptor)
            .filter { includingDeletedInHK || !$0.deletedInHK }
            .map { try $0.asDietarySampleData() }
            .sorted(by: DietarySampleData.displayOrder)
    }

    private func dietaryMirror(hkUUID: UUID) throws -> DietarySampleMirror? {
        var descriptor = FetchDescriptor<DietarySampleMirror>(predicate: #Predicate { $0.hkUUID == hkUUID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

fileprivate extension DietarySampleMirror {
    func asDietarySampleData() throws -> DietarySampleData {
        do {
            return DietarySampleData(
                hkUUID: hkUUID,
                date: date,
                energy: try Kilocalories(validating: kcal),
                protein: try proteinG.map { try Grams(validating: $0) },
                carbs: try carbsG.map { try Grams(validating: $0) },
                fat: try fatG.map { try Grams(validating: $0) },
                sourceBundleID: sourceBundleID,
                deletedInHK: deletedInHK
            )
        } catch {
            throw DietaryStoreError.invalidStoredSample(hkUUID)
        }
    }
}

fileprivate extension DietarySampleData {
    static func displayOrder(_ lhs: DietarySampleData, _ rhs: DietarySampleData) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.hkUUID.uuidString < rhs.hkUUID.uuidString
    }
}
