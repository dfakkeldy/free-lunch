// SPDX-License-Identifier: GPL-3.0-or-later
// The Health adapter's weight lane: spec §6 acceptance #5 (write order),
// anchored backfill and deletions into the WeightSampleMirror (§1, §10
// Weight), FL-authored edit and delete, and degraded access (§11).
import FLCore
import Foundation
import Testing
@testable import FLPersistence

private struct InjectedFailure: Error, Equatable {}

@MainActor
@Suite("Spec §6 acceptance #5: a manual weigh-in lands in Apple Health before the mirror")
struct HealthWeighInOrderTests {
    @Test("the HealthKit save comes first and the mirror row is built from the saved sample")
    func healthKitFirstThenMirror() async throws {
        let harness = try HealthHarness()
        var mirrorAtSave: [WeightSampleData]?
        harness.health.onSave = { _ in
            mirrorAtSave = try harness.mirror()
        }

        let saved = try await harness.sync.logWeighIn(Kilograms(81.6), at: at(day: 3, hour: 7))

        #expect(harness.log.entries == ["hk.save", "mirror.upsert"])
        // While the sample was being saved to Apple Health, no mirror row existed.
        #expect(mirrorAtSave == [])
        // The row is the sample Apple Health holds: its UUID, time and source.
        #expect(harness.health.liveSamples == [saved])
        #expect(try harness.mirror() == [saved])
        #expect(saved.sourceBundleID == ownBundleID)
        #expect(saved.weightKg == 81.6)
    }

    @Test("a failed HealthKit save mirrors nothing")
    func failedSaveMirrorsNothing() async throws {
        let harness = try HealthHarness()
        harness.health.saveError = InjectedFailure()

        await #expect(throws: InjectedFailure.self) {
            try await harness.sync.logWeighIn(Kilograms(81.6), at: at(day: 3))
        }
        #expect(harness.log.entries == ["hk.save"])
        #expect(try harness.mirror().isEmpty)
    }

    @Test("a weight that isn't positive is refused before Apple Health is touched")
    func zeroWeightRefused() async throws {
        let harness = try HealthHarness()

        await #expect(throws: WeightStoreError.invalidWeight(0)) {
            try await harness.sync.logWeighIn(Kilograms(0), at: at(day: 3))
        }
        #expect(harness.log.entries.isEmpty)
    }

    @Test("the weigh-in mirrors back once: a later sync re-delivers it idempotently")
    func laterSyncIsIdempotent() async throws {
        let harness = try HealthHarness()
        let saved = try await harness.sync.logWeighIn(Kilograms(81.6), at: at(day: 3))

        let result = try await harness.sync.sync()

        #expect(result == .synced(upserted: 1, markedDeleted: 0, skipped: 0))
        #expect(try harness.mirror() == [saved])
    }
}

@MainActor
@Suite("Anchored weight sync into the WeightSampleMirror")
struct HealthWeightMirrorSyncTests {
    @Test("the first sync backfills the whole history, page by page, from a nil anchor")
    func backfillFromStartOfHistory() async throws {
        let harness = try HealthHarness(pageLimit: 2)
        let history = [
            healthWeight(1, day: -900, kilograms: 95.2),
            healthWeight(2, day: -400, kilograms: 90.4, source: "org.example.other-scale"),
            healthWeight(3, day: -30, kilograms: 84.0),
            healthWeight(4, day: -1, kilograms: 83.1, source: ownBundleID)
        ]
        history.forEach(harness.health.seed)

        let result = try await harness.sync.sync()

        #expect(result == .synced(upserted: 4, markedDeleted: 0, skipped: 0))
        #expect(try harness.mirror() == history)
        // Pages of two, then an empty page that ends the pass.
        #expect(harness.health.queriedAnchors == [
            nil, MockHealthStore.anchor(2), MockHealthStore.anchor(4)
        ])
        #expect(harness.anchors.anchor(for: .bodyMass) == MockHealthStore.anchor(4))
    }

    @Test("the next sync resumes from the stored anchor and applies adds and deletions")
    func incrementalAddsAndDeletions() async throws {
        let harness = try HealthHarness()
        let kept = healthWeight(1, day: 0, kilograms: 84.0)
        let removed = healthWeight(2, day: 1, kilograms: 83.8)
        harness.health.seed(kept)
        harness.health.seed(removed)
        try await harness.sync.sync()

        let added = healthWeight(3, day: 2, kilograms: 83.5)
        harness.health.seed(added)
        harness.health.externalDelete(removed.hkUUID)
        let result = try await harness.sync.sync()

        #expect(result == .synced(upserted: 1, markedDeleted: 1, skipped: 0))
        // The second pass started where the first stopped.
        #expect(harness.health.queriedAnchors.dropFirst(2).first == MockHealthStore.anchor(2))
        var flagged = removed
        flagged.deletedInHK = true
        // The deleted row survives, flagged, so corrections that point at it stay resolvable.
        #expect(try harness.mirror() == [kept, flagged, added])
        #expect(try harness.mirror(includingDeleted: false) == [kept, added])
        #expect(try harness.store.correctedWeightView().map(\.hkUUID) == [kept.hkUUID, added.hkUUID])
    }

    @Test("a deletion of a sample that was never mirrored is ignored")
    func deletionOfUnknownSampleIgnored() async throws {
        let harness = try HealthHarness()
        harness.health.externalDelete(uid(404))

        let result = try await harness.sync.sync()

        #expect(result == .synced(upserted: 0, markedDeleted: 0, skipped: 0))
        #expect(try harness.mirror().isEmpty)
    }

    @Test("a sample the mirror can't hold is skipped and the rest still land")
    func invalidSampleSkipped() async throws {
        let harness = try HealthHarness()
        let good = healthWeight(1, day: 0, kilograms: 84.0)
        let zero = healthWeight(2, day: 1, kilograms: 0)
        let later = healthWeight(3, day: 2, kilograms: 83.7)
        [good, zero, later].forEach(harness.health.seed)

        let result = try await harness.sync.sync()

        #expect(result == .synced(upserted: 2, markedDeleted: 0, skipped: 1))
        #expect(try harness.mirror() == [good, later])
    }

    @Test("samples the adapter can't read are counted as skipped, and a full page of them doesn't end the pass")
    func unreadablePageDoesNotEndPass() async throws {
        let harness = try HealthHarness(pageLimit: 2)
        harness.health.seedUnreadable()
        harness.health.seedUnreadable()
        let later = healthWeight(1, day: 2, kilograms: 83.7)
        harness.health.seed(later)

        let result = try await harness.sync.sync()

        #expect(result == .synced(upserted: 1, markedDeleted: 0, skipped: 2))
        #expect(try harness.mirror() == [later])
    }

    @Test("a mirror write failure leaves the anchor where it was, so the next pass replays")
    func failedWriteDoesNotAdvanceAnchor() async throws {
        let harness = try HealthHarness()
        let first = healthWeight(1, day: 0, kilograms: 84.0)
        harness.health.seed(first)
        try await harness.sync.sync()
        let stored = harness.anchors.anchor(for: .bodyMass)

        let second = healthWeight(2, day: 1, kilograms: 83.9)
        harness.health.seed(second)
        harness.weights.upsertError = InjectedFailure()
        await #expect(throws: InjectedFailure.self) {
            try await harness.sync.sync()
        }
        #expect(harness.anchors.anchor(for: .bodyMass) == stored)

        let result = try await harness.sync.sync()
        #expect(result == .synced(upserted: 1, markedDeleted: 0, skipped: 0))
        #expect(try harness.mirror() == [first, second])
    }

    @Test("the anchor persists in UserDefaults across service instances")
    func anchorPersistsAcrossLaunches() async throws {
        let suite = "fl-health-anchor-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstLaunch = try HealthHarness(anchors: UserDefaultsHealthAnchorStore(defaults: defaults))
        firstLaunch.health.seed(healthWeight(1, day: 0, kilograms: 84.0))
        firstLaunch.health.seed(healthWeight(2, day: 1, kilograms: 83.9))
        try await firstLaunch.sync.sync()

        // A new launch: a new service and anchor store over the same defaults.
        let relaunched = UserDefaultsHealthAnchorStore(defaults: defaults)
        #expect(relaunched.anchor(for: .bodyMass) == MockHealthStore.anchor(2))
        let resumed = HealthWeightSync(
            health: firstLaunch.health,
            weights: firstLaunch.weights,
            anchors: relaunched
        )
        let queriedBefore = firstLaunch.health.queriedAnchors.count
        // A restart from nil would upsert both samples again.
        #expect(try await resumed.sync() == .synced(upserted: 0, markedDeleted: 0, skipped: 0))
        #expect(Array(firstLaunch.health.queriedAnchors.dropFirst(queriedBefore)) == [MockHealthStore.anchor(2)])

        relaunched.setAnchor(nil, for: .bodyMass)
        #expect(UserDefaultsHealthAnchorStore(defaults: defaults).anchor(for: .bodyMass) == nil)
    }
}

@MainActor
@Suite("Overlapping sync calls")
struct HealthWeightSyncOverlapTests {
    /// Holds a query open until the test lets it return.
    @MainActor
    private final class Gate {
        var waiting: CheckedContinuation<Void, Never>?

        func hold() async {
            await withCheckedContinuation { waiting = $0 }
        }

        func release() {
            waiting?.resume()
            waiting = nil
        }
    }

    @Test("a second sync while one is running joins it instead of starting another pass")
    func overlappingSyncsShareOnePass() async throws {
        let harness = try HealthHarness()
        let sample = healthWeight(1, day: 0, kilograms: 84.0)
        harness.health.seed(sample)
        let gate = Gate()
        harness.health.beforeQueryReturns = { [health = harness.health] in
            health.beforeQueryReturns = nil
            await gate.hold()
        }

        let first = Task { try await harness.sync.sync() }
        while gate.waiting == nil { await Task.yield() }
        let second = Task { try await harness.sync.sync() }
        for _ in 0..<20 { await Task.yield() }
        // Meanwhile Apple Health deletes the sample.
        harness.health.externalDelete(sample.hkUUID)
        gate.release()
        let results = try await (first.value, second.value)

        // One pass: the held page, the deletion page, then the empty page.
        #expect(harness.health.queriedAnchors == [
            nil, MockHealthStore.anchor(1), MockHealthStore.anchor(2)
        ])
        #expect(results.0 == .synced(upserted: 1, markedDeleted: 1, skipped: 0))
        #expect(results.1 == results.0)
        #expect(try harness.mirror().map(\.deletedInHK) == [true])
        #expect(harness.anchors.anchor(for: .bodyMass) == MockHealthStore.anchor(2))
    }
}

@MainActor
@Suite("Spec §6: FL-authored weigh-ins edit and delete; other sources don't")
struct HealthWeighInOwnershipTests {
    @Test("canModify is true only for live samples this app wrote")
    func canModifyOwnLiveSamplesOnly() throws {
        let harness = try HealthHarness()
        var own = healthWeight(1, day: 0, kilograms: 84.0, source: ownBundleID)
        #expect(harness.sync.canModify(own))
        #expect(!harness.sync.canModify(healthWeight(2, day: 0, kilograms: 84.0)))
        own.deletedInHK = true
        #expect(!harness.sync.canModify(own))
    }

    @Test("editing saves the replacement, deletes the original, then mirrors both")
    func editOwnWeighIn() async throws {
        let harness = try HealthHarness()
        let original = try await harness.sync.logWeighIn(Kilograms(82.0), at: at(day: 1, hour: 7))

        let replacement = try await harness.sync.editWeighIn(
            hkUUID: original.hkUUID,
            weight: Kilograms(81.4),
            at: at(day: 1, hour: 8)
        )

        #expect(harness.log.entries.dropFirst(2) == [
            "hk.save", "hk.delete", "mirror.upsert", "mirror.markDeleted"
        ])
        #expect(harness.health.liveSamples == [replacement])
        #expect(try harness.mirror(includingDeleted: false) == [replacement])
        #expect(try harness.mirror().first { $0.hkUUID == original.hkUUID }?.deletedInHK == true)
    }

    @Test("if the original can't be deleted, the replacement is still mirrored")
    func editWhenDeleteFails() async throws {
        let harness = try HealthHarness()
        let original = try await harness.sync.logWeighIn(Kilograms(82.0), at: at(day: 1))
        harness.health.deleteError = InjectedFailure()

        await #expect(throws: InjectedFailure.self) {
            try await harness.sync.editWeighIn(hkUUID: original.hkUUID, weight: Kilograms(81.4), at: at(day: 1))
        }
        // Both are in Apple Health, so both are mirrored; nothing is lost.
        #expect(harness.health.liveSamples.count == 2)
        #expect(try harness.mirror(includingDeleted: false).count == 2)
    }

    @Test("deleting removes the sample from Apple Health first, then flags the mirror row")
    func deleteOwnWeighIn() async throws {
        let harness = try HealthHarness()
        let saved = try await harness.sync.logWeighIn(Kilograms(82.0), at: at(day: 1))

        try await harness.sync.deleteWeighIn(hkUUID: saved.hkUUID)

        #expect(harness.log.entries.dropFirst(2) == ["hk.delete", "mirror.markDeleted"])
        #expect(harness.health.liveSamples.isEmpty)
        #expect(try harness.mirror(includingDeleted: false).isEmpty)
        #expect(try harness.mirror().map(\.deletedInHK) == [true])
    }

    @Test("another source's sample is refused before Apple Health is touched")
    func thirdPartySamplesAreImmutable() async throws {
        let harness = try HealthHarness()
        let scale = healthWeight(1, day: 0, kilograms: 84.0)
        harness.health.seed(scale)
        try await harness.sync.sync()
        let before = harness.log.entries

        await #expect(throws: FreeLunchStoreError.importedRecordImmutable(scale.hkUUID)) {
            try await harness.sync.editWeighIn(hkUUID: scale.hkUUID, weight: Kilograms(80), at: at(day: 0))
        }
        await #expect(throws: FreeLunchStoreError.importedRecordImmutable(scale.hkUUID)) {
            try await harness.sync.deleteWeighIn(hkUUID: scale.hkUUID)
        }
        #expect(harness.log.entries == before)
        #expect(try harness.mirror() == [scale])
        // The Correction path still applies to it.
        try harness.store.addCorrection(CorrectionData(
            createdAt: at(day: 1),
            targetKind: .hkWeightSample,
            targetID: scale.hkUUID.uuidString,
            action: .exclude
        ))
        #expect(try harness.store.correctedWeightView().isEmpty)
    }

    @Test("a delete Apple Health refuses as another source's leaves the mirror row live")
    func deleteRefusedBySourceKeepsRow() async throws {
        let harness = try HealthHarness()
        // The mirror believes the row is this app's, but Apple Health holds
        // it under another source.
        let mislabelled = healthWeight(1, day: 0, kilograms: 84.0, source: ownBundleID)
        try harness.store.upsertWeightSample(mislabelled)
        harness.health.seed(healthWeight(1, day: 0, kilograms: 84.0))

        await #expect(throws: FreeLunchStoreError.importedRecordImmutable(mislabelled.hkUUID)) {
            try await harness.sync.deleteWeighIn(hkUUID: mislabelled.hkUUID)
        }
        #expect(!harness.log.entries.contains("mirror.markDeleted"))
        #expect(try harness.mirror(includingDeleted: false) == [mislabelled])
    }

    @Test("a sample that isn't in the mirror can't be edited or deleted")
    func unknownSampleRefused() async throws {
        let harness = try HealthHarness()

        await #expect(throws: FreeLunchStoreError.notFound(uid(9))) {
            try await harness.sync.deleteWeighIn(hkUUID: uid(9))
        }
        #expect(harness.log.entries.isEmpty)
    }
}

@MainActor
@Suite("Spec §11: denied or partial Health access degrades without crashing")
struct HealthAccessDegradationTests {
    @Test("access status is readable per type for Settings")
    func statusPerType() throws {
        let harness = try HealthHarness()
        for status in [HealthAuthorizationStatus.notDetermined, .sharingDenied, .sharingAuthorized] {
            harness.health.sharing[.bodyMass] = status
            #expect(harness.sync.accessStatuses() == [HealthAccessStatus(type: .bodyMass, sharing: status)])
        }
        harness.health.isHealthDataAvailable = false
        #expect(harness.sync.accessStatuses() == [HealthAccessStatus(type: .bodyMass, sharing: .unavailable)])
    }

    @Test("the re-request path asks for read and write weight access and reports whether the sheet will show")
    func reRequestPath() async throws {
        let harness = try HealthHarness()
        #expect(try await harness.sync.accessRequestStatus() == .shouldRequest)
        try await harness.sync.requestAccess()
        #expect(harness.health.requestedAuthorization.count == 1)
        #expect(harness.health.requestedAuthorization.first?.share == [.bodyMass])
        #expect(harness.health.requestedAuthorization.first?.read == [.bodyMass])

        harness.health.requestStatus = .unnecessary
        #expect(try await harness.sync.accessRequestStatus() == .unnecessary)
    }

    @Test("sync never prompts for access")
    func syncNeverPrompts() async throws {
        let harness = try HealthHarness()
        harness.health.sharing[.bodyMass] = .notDetermined
        try await harness.sync.sync()
        #expect(!harness.log.entries.contains("hk.requestAuthorization"))
    }

    @Test("without Health data, sync degrades and nothing is touched")
    func unavailableDevice() async throws {
        let harness = try HealthHarness()
        harness.health.isHealthDataAvailable = false

        #expect(try await harness.sync.sync() == .degraded(.unavailable))
        await #expect(throws: HealthAccessError.unavailable) {
            try await harness.sync.logWeighIn(Kilograms(80), at: at(day: 0))
        }
        await #expect(throws: HealthAccessError.unavailable) {
            try await harness.sync.requestAccess()
        }
        // Not "unnecessary": that would send the user to a Health app the
        // device doesn't have.
        #expect(try await harness.sync.accessRequestStatus() == .unknown)
        #expect(harness.log.entries.isEmpty)
        #expect(harness.anchors.anchor(for: .bodyMass) == nil)
    }

    @Test("a query refused for access degrades and leaves mirror and anchor unchanged")
    func queryAccessErrorDegrades() async throws {
        let harness = try HealthHarness()
        harness.health.seed(healthWeight(1, day: 0, kilograms: 84.0))
        harness.health.queryError = HealthAccessError.authorizationNotDetermined(.bodyMass)

        #expect(try await harness.sync.sync() == .degraded(.authorizationNotDetermined(.bodyMass)))
        #expect(try harness.mirror().isEmpty)
        #expect(harness.anchors.anchor(for: .bodyMass) == nil)

        // Once access is there, the same pass backfills.
        #expect(try await harness.sync.sync() == .synced(upserted: 1, markedDeleted: 0, skipped: 0))
    }

    @Test("adapter contract: a page with no changes completes a pass without touching the mirror")
    func emptyPageCompletesPass() async throws {
        let harness = try HealthHarness()
        // The mock models HealthKit's denied read: no samples, no error.
        harness.health.readDenied = true
        harness.health.seed(healthWeight(1, day: 0, kilograms: 84.0))

        #expect(try await harness.sync.sync() == .synced(upserted: 0, markedDeleted: 0, skipped: 0))
        #expect(try harness.mirror().isEmpty)
    }

    @Test("read denied at the first sync, then allowed on the sheet: requesting access backfills the full history")
    func requestAccessRestartsBackfill() async throws {
        let harness = try HealthHarness()
        harness.health.readDenied = true
        let scale = healthWeight(1, day: 0, kilograms: 84.0)
        harness.health.seed(scale)
        try await harness.sync.sync()
        // The stored anchor is now past the hidden sample.
        #expect(harness.anchors.anchor(for: .bodyMass) == MockHealthStore.anchor(1))

        harness.health.readDenied = false
        try await harness.sync.requestAccess()
        #expect(harness.anchors.anchor(for: .bodyMass) == nil)
        #expect(try await harness.sync.sync() == .synced(upserted: 1, markedDeleted: 0, skipped: 0))
        #expect(try harness.mirror() == [scale])
    }

    @Test("read turned on later in the Health app: resyncing from the start brings in the hidden history")
    func resyncFromStartAfterReadAllowed() async throws {
        let harness = try HealthHarness()
        harness.health.readDenied = true
        let scale = healthWeight(1, day: 0, kilograms: 84.0)
        let own = healthWeight(2, day: 1, kilograms: 83.6, source: ownBundleID)
        let removed = healthWeight(3, day: 2, kilograms: 83.4, source: ownBundleID)
        [scale, own, removed].forEach(harness.health.seed)
        try await harness.sync.sync()
        #expect(try harness.mirror() == [scale, own, removed].filter { $0.sourceBundleID == ownBundleID })

        // Reading allowed in the Health app: no sheet, so no requestAccess.
        harness.health.readDenied = false
        harness.health.requestStatus = .unnecessary
        harness.health.externalDelete(removed.hkUUID)
        // A plain sync resumes past the hidden sample and never sees it.
        #expect(try await harness.sync.sync() == .synced(upserted: 0, markedDeleted: 1, skipped: 0))
        #expect(try harness.mirror(includingDeleted: false) == [own])

        let result = try await harness.sync.resyncFromStart()

        // The mock replays its whole journal from a nil anchor, so the
        // deleted sample comes back as an add and then its deletion.
        #expect(result == .synced(upserted: 3, markedDeleted: 1, skipped: 0))
        #expect(try harness.mirror(includingDeleted: false) == [scale, own])
        #expect(try harness.mirror().first { $0.hkUUID == removed.hkUUID }?.deletedInHK == true)
    }

    @Test("a locked device degrades the sync instead of failing it")
    func lockedDeviceDegrades() async throws {
        let harness = try HealthHarness()
        harness.health.queryError = HealthAccessError.temporarilyUnavailable

        #expect(try await harness.sync.sync() == .degraded(.temporarilyUnavailable))
        #expect(harness.anchors.anchor(for: .bodyMass) == nil)
    }

    @Test("partial access: write denied refuses weigh-ins while reading still syncs")
    func writeDeniedReadAllowed() async throws {
        let harness = try HealthHarness()
        harness.health.sharing[.bodyMass] = .sharingDenied
        let scale = healthWeight(1, day: 0, kilograms: 84.0)
        harness.health.seed(scale)

        await #expect(throws: HealthAccessError.authorizationDenied(.bodyMass)) {
            try await harness.sync.logWeighIn(Kilograms(83.0), at: at(day: 1))
        }
        #expect(!harness.log.entries.contains("hk.save"))

        #expect(try await harness.sync.sync() == .synced(upserted: 1, markedDeleted: 0, skipped: 0))
        #expect(try harness.mirror() == [scale])
    }

    @Test("write access not yet asked for refuses weigh-ins with a typed error")
    func writeNotDetermined() async throws {
        let harness = try HealthHarness()
        harness.health.sharing[.bodyMass] = .notDetermined

        await #expect(throws: HealthAccessError.authorizationNotDetermined(.bodyMass)) {
            try await harness.sync.logWeighIn(Kilograms(83.0), at: at(day: 1))
        }
        #expect(harness.log.entries.isEmpty)
    }
}
