// SPDX-License-Identifier: GPL-3.0-or-later
// Apple Health weight in Free Lunch (spec §1 Weight, §6 Weigh-ins &
// corrections, §10 Weight, §11 Health access).
//
// HealthKit is canonical for weight. The WeightSampleMirror is a local cache
// kept by anchored queries: the first sync backfills it from the start of the
// user's history, later syncs apply only what changed. A manual weigh-in is
// written to HealthKit first and its mirror row is built from the sample
// HealthKit saved, never written on its own. Samples this app wrote edit and
// delete normally; every other source's samples are corrected with
// Correction records instead (`WeightStore.addCorrection`).
import FLCore
import Foundation

@MainActor
public final class HealthWeightSync {
    /// The types the weight lane asks for: it reads and writes body mass.
    public static let accessTypes: Set<HealthDataType> = [.bodyMass]
    /// Samples per anchored-query page during a backfill.
    public static let defaultPageLimit = 500

    /// The bundle identifier Apple Health records as the source of this
    /// app's samples. Injected rather than read from `Bundle.main`, which is
    /// the test runner on the package test host.
    public let ownSourceBundleID: String

    let health: any HealthStoreAdapter
    let weights: any WeightStore
    let anchors: any HealthAnchorStore
    let pageLimit: Int

    public init(
        health: any HealthStoreAdapter,
        weights: any WeightStore,
        anchors: any HealthAnchorStore,
        ownSourceBundleID: String,
        pageLimit: Int = HealthWeightSync.defaultPageLimit
    ) {
        precondition(pageLimit > 0, "pageLimit must be positive")
        self.health = health
        self.weights = weights
        self.anchors = anchors
        self.ownSourceBundleID = ownSourceBundleID
        self.pageLimit = pageLimit
    }

    // MARK: Access (Settings → Health access)

    /// Write access per type, in a stable order, for the Settings list.
    public func accessStatuses() -> [HealthAccessStatus] {
        HealthDataType.allCases
            .filter { Self.accessTypes.contains($0) }
            .map { type in
                HealthAccessStatus(
                    type: type,
                    sharing: health.isHealthDataAvailable ? health.authorizationStatus(for: type) : .unavailable
                )
            }
    }

    /// Whether the re-request path would show the system sheet, or should
    /// send the user to the Health app instead.
    public func accessRequestStatus() async throws -> HealthAuthorizationRequestStatus {
        guard health.isHealthDataAvailable else { return .unnecessary }
        return try await health.authorizationRequestStatus(toShare: Self.accessTypes, read: Self.accessTypes)
    }

    /// Asks for read and write access to the weight lane's types. Only an
    /// explicit user action calls this; `sync` never prompts.
    public func requestAccess() async throws {
        guard health.isHealthDataAvailable else { throw HealthAccessError.unavailable }
        try await health.requestAuthorization(toShare: Self.accessTypes, read: Self.accessTypes)
    }

    // MARK: Mirror sync

    /// Brings the mirror up to date from the stored anchor (from the start
    /// of history when there is none), page by page.
    ///
    /// Each page applies additions, then deletions, then stores the page's
    /// anchor, so a failure part-way leaves the anchor at the last page fully
    /// applied and the next pass replays the rest. Replays are harmless:
    /// upserts are idempotent and a deletion only sets `deletedInHK`.
    ///
    /// When Apple Health is out of reach the result is `.degraded` and
    /// nothing changes. A denied read can't be detected (HealthKit hides it)
    /// and simply yields no samples.
    @discardableResult
    public func sync() async throws -> HealthSyncResult {
        guard health.isHealthDataAvailable else { return .degraded(.unavailable) }
        var upserted = 0
        var markedDeleted = 0
        var skipped = 0
        while true {
            let changes: HealthWeightChanges
            do {
                changes = try await health.weightChanges(after: anchors.anchor(for: .bodyMass), limit: pageLimit)
            } catch let error as HealthAccessError {
                return .degraded(error)
            }
            for sample in changes.added {
                do {
                    try weights.upsertWeightSample(sample)
                    upserted += 1
                } catch WeightStoreError.invalidWeight {
                    skipped += 1
                }
            }
            for hkUUID in changes.deleted {
                do {
                    try weights.markWeightSampleDeletedInHK(hkUUID: hkUUID)
                    markedDeleted += 1
                } catch FreeLunchStoreError.notFound(let missing) where missing == hkUUID {
                    // Deleted before it was ever mirrored: nothing to flag.
                }
            }
            anchors.setAnchor(changes.anchor, for: .bodyMass)
            if changes.isEmpty { break }
        }
        return .synced(upserted: upserted, markedDeleted: markedDeleted, skipped: skipped)
    }

    // MARK: Weigh-ins

    /// True for a live sample this app wrote: only those edit and delete in
    /// place. Any other source's sample takes a Correction.
    public func canModify(_ sample: WeightSampleData) -> Bool {
        sample.sourceBundleID == ownSourceBundleID && !sample.deletedInHK
    }

    /// A manual weigh-in (spec §6). Written to Apple Health first; the mirror
    /// row is then built from the sample HealthKit saved. If the write fails
    /// nothing is mirrored.
    @discardableResult
    public func logWeighIn(_ weight: Kilograms, at date: Date) async throws -> WeightSampleData {
        try Self.requirePositive(weight)
        try requireWriteAccess()
        let saved = try await health.saveWeight(weight, at: date)
        try weights.upsertWeightSample(saved)
        return saved
    }

    /// Changes a weigh-in this app wrote. HealthKit samples are immutable,
    /// so this saves a replacement and then deletes the original — in that
    /// order, so a failure can leave a duplicate but never lose the weigh-in.
    /// Another source's sample is refused before Apple Health is touched.
    @discardableResult
    public func editWeighIn(hkUUID: UUID, weight: Kilograms, at date: Date) async throws -> WeightSampleData {
        try Self.requirePositive(weight)
        try requireModifiable(hkUUID)
        try requireWriteAccess()
        let saved = try await health.saveWeight(weight, at: date)
        do {
            try await health.deleteWeight(hkUUID: hkUUID)
        } catch {
            // The replacement is in Apple Health, so mirror it; the original
            // stays until a retry or the user deletes it.
            try weights.upsertWeightSample(saved)
            throw error
        }
        try weights.upsertWeightSample(saved)
        try weights.markWeightSampleDeletedInHK(hkUUID: hkUUID)
        return saved
    }

    /// Deletes a weigh-in this app wrote, from Apple Health first and then
    /// from the mirror (flagged `deletedInHK`, as a sync would). Another
    /// source's sample is refused before Apple Health is touched.
    public func deleteWeighIn(hkUUID: UUID) async throws {
        try requireModifiable(hkUUID)
        try requireWriteAccess()
        try await health.deleteWeight(hkUUID: hkUUID)
        try weights.markWeightSampleDeletedInHK(hkUUID: hkUUID)
    }

    // MARK: Private

    private static func requirePositive(_ weight: Kilograms) throws {
        guard weight.value > 0 else { throw WeightStoreError.invalidWeight(weight.value) }
    }

    private func requireWriteAccess() throws {
        guard health.isHealthDataAvailable else { throw HealthAccessError.unavailable }
        switch health.authorizationStatus(for: .bodyMass) {
        case .sharingAuthorized: return
        case .unavailable: throw HealthAccessError.unavailable
        case .notDetermined: throw HealthAccessError.authorizationNotDetermined(.bodyMass)
        case .sharingDenied: throw HealthAccessError.authorizationDenied(.bodyMass)
        }
    }

    private func requireModifiable(_ hkUUID: UUID) throws {
        guard let sample = try weights.weightSamples(includingDeletedInHK: false).first(where: { $0.hkUUID == hkUUID }) else {
            throw FreeLunchStoreError.notFound(hkUUID)
        }
        guard canModify(sample) else {
            throw FreeLunchStoreError.importedRecordImmutable(hkUUID)
        }
    }
}
