// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #3: immutable corrections leave HealthKit mirrors alone.
import FLCore
import Foundation
import Testing
@testable import FLPersistence

private func weightMirror(_ number: Int, day: Double, kilograms: Double) -> WeightSampleData {
    WeightSampleData(
        hkUUID: uid(number),
        measuredAt: at(day: day),
        weight: Kilograms(kilograms),
        sourceBundleID: "com.example.scale"
    )
}

private func weightCorrection(
    _ number: Int,
    target: UUID,
    day: Double,
    action: CorrectionAction = .replace,
    replacement: Data? = nil
) -> CorrectionData {
    CorrectionData(
        id: uid(number),
        createdAt: at(day: day, hour: 12),
        targetKind: .hkWeightSample,
        targetID: target.uuidString,
        action: action,
        replacement: replacement
    )
}

private func sameWeightMirrorBits(_ lhs: WeightSampleData, _ rhs: WeightSampleData) -> Bool {
    lhs.hkUUID == rhs.hkUUID
        && lhs.measuredAt == rhs.measuredAt
        && lhs.weightKg.bitPattern == rhs.weightKg.bitPattern
        && lhs.sourceBundleID == rhs.sourceBundleID
        && lhs.deletedInHK == rhs.deletedInHK
}

@MainActor
@Suite("Spec §1 acceptance #3: correction immutability")
struct WeightCorrectionTests {
    private func mirrorFixture(_ store: SwiftDataStore) throws -> [WeightSampleData] {
        let samples = [
            weightMirror(9001, day: 0, kilograms: 82.4),
            weightMirror(9002, day: 1, kilograms: 82.1),
            weightMirror(9003, day: 2, kilograms: 81.9)
        ]
        for sample in samples {
            try store.upsertWeightSample(sample)
        }
        return samples
    }

    @Test("replace changes only the derived view, and deletion restores it")
    func replaceAndDeleteRestoreOriginalView() throws {
        let store = try makeInMemoryStore()
        let originals = try mirrorFixture(store)
        let originalView = try store.correctedWeightView()
        let replacement = try WeightSampleReplacement(weight: Kilograms(80.1)).encoded()
        let correction = weightCorrection(9010, target: originals[1].hkUUID, day: 3, replacement: replacement)

        try store.addCorrection(correction)

        let rawAfterReplace = try store.weightSamples(includingDeletedInHK: true)
        #expect(zip(rawAfterReplace, originals).allSatisfy(sameWeightMirrorBits))
        let corrected = try store.correctedWeightView()
        #expect(corrected.map(\.weightKg) == [82.4, 80.1, 81.9])
        #expect(corrected[0].correctionID == nil)
        #expect(corrected[1].correctionID == correction.id)
        #expect(corrected[2].correctionID == nil)
        #expect(try store.rowCount(WeightSampleMirror.self) == 3)
        #expect(try store.rowCount(Correction.self) == 1)

        try store.deleteCorrection(id: correction.id)

        #expect(try store.correctedWeightView() == originalView)
        let rawAfterDelete = try store.weightSamples(includingDeletedInHK: true)
        #expect(zip(rawAfterDelete, originals).allSatisfy(sameWeightMirrorBits))
        #expect(try store.rowCount(Correction.self) == 0)
    }

    @Test("exclude hides a mirror sample but deleting the correction restores it")
    func excludeAndRestore() throws {
        let store = try makeInMemoryStore()
        let originals = try mirrorFixture(store)
        let correction = weightCorrection(9011, target: originals[1].hkUUID, day: 3, action: .exclude)

        try store.addCorrection(correction)
        #expect(try store.correctedWeightView().map(\.hkUUID) == [originals[0].hkUUID, originals[2].hkUUID])
        #expect(try store.weightSamples(includingDeletedInHK: true).count == 3)

        try store.deleteCorrection(id: correction.id)
        #expect(try store.correctedWeightView().map(\.hkUUID) == originals.map(\.hkUUID))
    }

    @Test("newest correction wins and removing it re-exposes the prior one")
    func newestCorrectionWins() throws {
        let store = try makeInMemoryStore()
        let originals = try mirrorFixture(store)
        let older = weightCorrection(
            9012,
            target: originals[1].hkUUID,
            day: 3,
            replacement: try WeightSampleReplacement.encode(weight: Kilograms(80.1))
        )
        let newer = weightCorrection(
            9013,
            target: originals[1].hkUUID,
            day: 4,
            replacement: try WeightSampleReplacement.encode(weight: Kilograms(79.9))
        )

        try store.addCorrection(older)
        try store.addCorrection(newer)
        #expect(try store.correctedWeightView()[1].weightKg == 79.9)
        #expect(try store.correctedWeightView()[1].correctionID == newer.id)

        try store.deleteCorrection(id: newer.id)
        #expect(try store.correctedWeightView()[1].weightKg == 80.1)
        #expect(try store.correctedWeightView()[1].correctionID == older.id)
    }

    @Test("an anchored-query refresh updates the mirror without removing its correction")
    func upsertAndHealthKitDeletion() throws {
        let store = try makeInMemoryStore()
        let originals = try mirrorFixture(store)
        let correction = weightCorrection(
            9014,
            target: originals[1].hkUUID,
            day: 3,
            replacement: try WeightSampleReplacement.encode(weight: Kilograms(80.1))
        )
        try store.addCorrection(correction)

        let refreshed = WeightSampleData(
            hkUUID: originals[1].hkUUID,
            measuredAt: at(day: 4),
            weight: Kilograms(82.2),
            sourceBundleID: "com.example.updated-scale"
        )
        try store.upsertWeightSample(refreshed)

        let raw = try store.weightSamples(includingDeletedInHK: true)
        let refreshedRaw = try #require(raw.first { $0.hkUUID == refreshed.hkUUID })
        #expect(refreshedRaw == refreshed)
        let corrected = try store.correctedWeightView()
        let correctedRefreshed = try #require(corrected.first { $0.hkUUID == refreshed.hkUUID })
        #expect(correctedRefreshed.weightKg == 80.1)
        #expect(correctedRefreshed.correctionID == correction.id)
        #expect(try store.corrections(targetKind: .hkWeightSample) == [correction])

        try store.markWeightSampleDeletedInHK(hkUUID: refreshed.hkUUID)
        #expect(try store.weightSamples(includingDeletedInHK: false).count == 2)
        let deletedRaw = try #require(try store.weightSamples(includingDeletedInHK: true).first { $0.hkUUID == refreshed.hkUUID })
        #expect(deletedRaw.deletedInHK)
        #expect(try store.correctedWeightView().contains { $0.hkUUID == refreshed.hkUUID } == false)
        #expect(try store.rowCount(WeightSampleMirror.self) == 3)
    }

    @Test("refused corrections leave mirrors and correction rows unchanged")
    func refusalIsAtomic() throws {
        let store = try makeInMemoryStore()
        let originals = try mirrorFixture(store)
        let valid = weightCorrection(
            9015,
            target: originals[0].hkUUID,
            day: 3,
            replacement: try WeightSampleReplacement.encode(weight: Kilograms(80.1))
        )
        try store.addCorrection(valid)
        let beforeMirrors = try store.weightSamples(includingDeletedInHK: true)
        let beforeCorrections = try store.corrections(targetKind: nil)

        #expect(throws: FreeLunchStoreError.duplicateID(valid.id)) { try store.addCorrection(valid) }

        let nilPayload = weightCorrection(9016, target: originals[0].hkUUID, day: 4)
        #expect(throws: WeightStoreError.invalidCorrection(nilPayload.id)) { try store.addCorrection(nilPayload) }

        let excludePayload = weightCorrection(
            9017,
            target: originals[0].hkUUID,
            day: 4,
            action: .exclude,
            replacement: Data("payload".utf8)
        )
        #expect(throws: WeightStoreError.invalidCorrection(excludePayload.id)) { try store.addCorrection(excludePayload) }

        let nonFinite = weightCorrection(
            9018,
            target: originals[0].hkUUID,
            day: 4,
            replacement: Data(#"{"measuredAt":null,"weightKg":"NaN"}"#.utf8)
        )
        #expect(throws: WeightStoreError.invalidCorrection(nonFinite.id)) { try store.addCorrection(nonFinite) }

        #expect(try store.weightSamples(includingDeletedInHK: true) == beforeMirrors)
        #expect(try store.corrections(targetKind: nil) == beforeCorrections)
    }

    @Test("corrections and the derived view survive a cold load")
    func correctionsPersistAcrossReopen() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }

        let expectedMirrors: [WeightSampleData]
        let expectedCorrections: [CorrectionData]
        let expectedView: [CorrectedWeightSample]
        do {
            let writer = try SwiftDataStore.phone(at: .file(url))
            let originals = try mirrorFixture(writer)
            let correction = weightCorrection(
                9019,
                target: originals[1].hkUUID,
                day: 3,
                replacement: try WeightSampleReplacement.encode(weight: Kilograms(80.1), measuredAt: at(day: 5))
            )
            try writer.addCorrection(correction)
            expectedMirrors = try writer.weightSamples(includingDeletedInHK: true)
            expectedCorrections = try writer.corrections(targetKind: nil)
            expectedView = try writer.correctedWeightView()
        }

        let reader = try SwiftDataStore.phone(at: .file(url))
        #expect(try reader.weightSamples(includingDeletedInHK: true) == expectedMirrors)
        #expect(try reader.corrections(targetKind: nil) == expectedCorrections)
        #expect(try reader.correctedWeightView() == expectedView)
    }

    @Test("corrected values are derived and kilograms remain canonical through the store")
    func correctedViewIsNotStoredAndCanonicalWeightRoundTrips() throws {
        let store = try makeInMemoryStore()
        let pounds = try Kilograms(Measurement(value: 180, unit: UnitMass.pounds))
        let sample = WeightSampleData(
            hkUUID: uid(9020),
            measuredAt: at(),
            weight: pounds,
            sourceBundleID: "com.example.scale"
        )
        try store.upsertWeightSample(sample)
        let correction = weightCorrection(9021, target: sample.hkUUID, day: 1, action: .exclude)
        try store.addCorrection(correction)

        let modelNames = FreeLunchSchemaCurrent.models.map { String(reflecting: $0) }
        let weightModels = modelNames.filter { $0.contains("Weight") || $0.contains("Correction") }
        #expect(weightModels.count == 2)
        #expect(weightModels.contains { $0.contains("WeightSampleMirror") })
        #expect(weightModels.contains { $0.contains("Correction") })
        #expect(!modelNames.contains { $0.contains("CorrectedWeight") })

        let mirrorsBefore = try store.rowCount(WeightSampleMirror.self)
        let correctionsBefore = try store.rowCount(Correction.self)
        let firstView = try store.correctedWeightView()
        let secondView = try store.correctedWeightView()
        #expect(firstView == secondView)
        #expect(try store.rowCount(WeightSampleMirror.self) == mirrorsBefore)
        #expect(try store.rowCount(Correction.self) == correctionsBefore)

        let stored = try #require(try store.weightSamples(includingDeletedInHK: true).first)
        #expect(abs(stored.weightKg - 81.6466266) < 0.000000001)
    }
}
