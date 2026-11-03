// SPDX-License-Identifier: GPL-3.0-or-later
// The real `HealthStoreAdapter`, over `HKHealthStore`. It lives in the
// package (not the phone target) so it compiles wherever the package does and
// sits next to the protocol it implements; it stays thin — type mapping and
// HealthKit calls only — because the logic above it is what the tests cover.
// FLPersistence is linked by the phone app alone, so no HealthKit write path
// is reachable from the watch (spec §9).
#if canImport(HealthKit)
import FLCore
import Foundation
import HealthKit

@MainActor
public final class HealthKitStoreAdapter: HealthStoreAdapter {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func authorizationStatus(for type: HealthDataType) -> HealthAuthorizationStatus {
        guard isHealthDataAvailable else { return .unavailable }
        switch store.authorizationStatus(for: Self.sampleType(type)) {
        case .notDetermined: return .notDetermined
        case .sharingDenied: return .sharingDenied
        case .sharingAuthorized: return .sharingAuthorized
        @unknown default: return .notDetermined
        }
    }

    public func authorizationRequestStatus(
        toShare: Set<HealthDataType>,
        read: Set<HealthDataType>
    ) async throws -> HealthAuthorizationRequestStatus {
        let status = try await mapped(.bodyMass) {
            try await store.statusForAuthorizationRequest(toShare: Self.sampleTypes(toShare), read: Self.objectTypes(read))
        }
        switch status {
        case .shouldRequest: return .shouldRequest
        case .unnecessary: return .unnecessary
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    public func requestAuthorization(toShare: Set<HealthDataType>, read: Set<HealthDataType>) async throws {
        try await mapped(.bodyMass) {
            try await store.requestAuthorization(toShare: Self.sampleTypes(toShare), read: Self.objectTypes(read))
        }
    }

    // MARK: Weight

    public func weightChanges(after anchor: HealthQueryAnchor?, limit: Int) async throws -> HealthWeightChanges {
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: Self.bodyMass)],
            anchor: anchor.flatMap(Self.unarchive),
            limit: limit
        )
        let result = try await mapped(.bodyMass) { try await descriptor.result(for: store) }
        return HealthWeightChanges(
            added: result.addedSamples.compactMap(Self.weightSample),
            deleted: result.deletedObjects.map(\.uuid),
            anchor: try Self.archive(result.newAnchor)
        )
    }

    public func saveWeight(_ weight: Kilograms, at date: Date) async throws -> WeightSampleData {
        let sample = HKQuantitySample(
            type: Self.bodyMass,
            quantity: HKQuantity(unit: Self.kilograms, doubleValue: weight.value),
            start: date,
            end: date,
            metadata: [HKMetadataKeyWasUserEntered: true]
        )
        try await mapped(.bodyMass) { try await store.save(sample) }
        // A sample this app saved has this app as its source.
        return WeightSampleData(
            hkUUID: sample.uuid,
            measuredAt: sample.startDate,
            weight: weight,
            sourceBundleID: HKSource.default().bundleIdentifier
        )
    }

    public func deleteWeight(hkUUID: UUID) async throws {
        let ownSample = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObject(with: hkUUID),
            HKQuery.predicateForObjects(from: HKSource.default())
        ])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: Self.bodyMass, predicate: ownSample)],
            sortDescriptors: [],
            limit: 1
        )
        let found = try await mapped(.bodyMass) { try await descriptor.result(for: store) }
        // Already gone from Apple Health: the deletion has happened.
        guard let sample = found.first else { return }
        try await mapped(.bodyMass) { try await store.delete(sample) }
    }

    // MARK: Mapping

    private static let bodyMass = HKQuantityType(.bodyMass)
    private static let kilograms = HKUnit.gramUnit(with: .kilo)

    private static func sampleType(_ type: HealthDataType) -> HKSampleType {
        switch type {
        case .bodyMass: bodyMass
        }
    }

    private static func sampleTypes(_ types: Set<HealthDataType>) -> Set<HKSampleType> {
        Set(types.map(sampleType))
    }

    private static func objectTypes(_ types: Set<HealthDataType>) -> Set<HKObjectType> {
        Set(types.map { sampleType($0) as HKObjectType })
    }

    /// A body-mass sample as a mirror value; nil for a value no weight can
    /// hold (HealthKit doesn't produce one, but the mirror never traps).
    private static func weightSample(_ sample: HKQuantitySample) -> WeightSampleData? {
        guard let weight = try? Kilograms(validating: sample.quantity.doubleValue(for: kilograms)) else {
            return nil
        }
        return WeightSampleData(
            hkUUID: sample.uuid,
            measuredAt: sample.startDate,
            weight: weight,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier
        )
    }

    private static func archive(_ anchor: HKQueryAnchor) throws -> HealthQueryAnchor {
        HealthQueryAnchor(data: try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true))
    }

    /// An unreadable stored anchor restarts from the beginning of history,
    /// which the idempotent mirror absorbs.
    private static func unarchive(_ anchor: HealthQueryAnchor) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor.data)
    }

    /// Runs one HealthKit call, turning the "out of reach" errors into
    /// `HealthAccessError` so callers degrade instead of failing.
    private func mapped<T>(_ type: HealthDataType, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as HKError {
            switch error.code {
            case .errorHealthDataUnavailable, .errorHealthDataRestricted:
                throw HealthAccessError.unavailable
            case .errorAuthorizationNotDetermined:
                throw HealthAccessError.authorizationNotDetermined(type)
            case .errorAuthorizationDenied:
                throw HealthAccessError.authorizationDenied(type)
            default:
                throw error
            }
        }
    }
}
#endif
