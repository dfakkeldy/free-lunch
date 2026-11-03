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
    /// app's samples, as the adapter that writes them reports it.
    public var ownSourceBundleID: String { health.ownSourceBundleID }

    let health: any HealthStoreAdapter
    let weights: any WeightStore
    let anchors: any HealthAnchorStore
    let pageLimit: Int
    /// The pass in progress, which an overlapping `sync` joins.
    private var running: Task<HealthSyncResult, any Error>?

    public init(
        health: any HealthStoreAdapter,
        weights: any WeightStore,
        anchors: any HealthAnchorStore,
        pageLimit: Int = HealthWeightSync.defaultPageLimit
    ) {
        precondition(pageLimit > 0, "pageLimit must be positive")
        self.health = health
        self.weights = weights
        self.anchors = anchors
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
    /// send the user to the Health app instead. `.unknown` on a device
    /// without Health data, which has no Health app to send them to.
    public func accessRequestStatus() async throws -> HealthAuthorizationRequestStatus {
        guard health.isHealthDataAvailable else { return .unknown }
        return try await health.authorizationRequestStatus(toShare: Self.accessTypes, read: Self.accessTypes)
    }

    /// Asks for read and write access to the weight lane's types. Only an
    /// explicit user action calls this; `sync` never prompts.
    ///
    /// Afterwards the anchor is forgotten, so the next `sync` backfills from
    /// the start: a pass that ran while reading was off stored an anchor
    /// past samples HealthKit hid, and it never delivers those again.
    public func requestAccess() async throws {
        guard health.isHealthDataAvailable else { throw HealthAccessError.unavailable }
        try await health.requestAuthorization(toShare: Self.accessTypes, read: Self.accessTypes)
        await forgetAnchor()
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
    /// When Apple Health is out of reach the result is `.degraded` and the
    /// anchor stays at the last page applied. A denied read can't be
    /// detected (HealthKit hides it) and yields no samples, yet the anchor
    /// still moves past them; `requestAccess` and `resyncFromStart` are how
    /// the hidden history comes in once reading is allowed.
    ///
    /// A call while a pass is running joins that pass and returns its
    /// result, so two passes never interleave their pages.
    @discardableResult
    public func sync() async throws -> HealthSyncResult {
        if let running { return try await running.value }
        // The pass clears `running` itself, on the main actor, before anyone
        // awaiting it resumes. It can't start before the assignment below:
        // this method doesn't suspend until it awaits the pass.
        let pass = Task { @MainActor in
            defer { self.running = nil }
            return try await self.runPass()
        }
        running = pass
        return try await pass.value
    }

    /// Catches up from the stored anchor (so recent deletions still land),
    /// then backfills the whole history again from the start. For the
    /// Settings backfill row, after the user changes access in the Health
    /// app. Re-delivered samples are idempotent upserts. The result is the
    /// backfill's, or the catch-up's if that one degraded.
    @discardableResult
    public func resyncFromStart() async throws -> HealthSyncResult {
        let catchUp = try await sync()
        if case .degraded = catchUp { return catchUp }
        await forgetAnchor()
        return try await sync()
    }

    private func runPass() async throws -> HealthSyncResult {
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
            skipped += changes.unreadable
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

    /// Waits out any running pass, which would otherwise store its own
    /// anchor over the reset, then clears the anchor.
    private func forgetAnchor() async {
        while let running {
            _ = try? await running.value
        }
        anchors.setAnchor(nil, for: .bodyMass)
    }

    private func requireModifiable(_ hkUUID: UUID) throws {
        guard let sample = try weights.weightSample(hkUUID: hkUUID), !sample.deletedInHK else {
            throw FreeLunchStoreError.notFound(hkUUID)
        }
        guard canModify(sample) else {
            throw FreeLunchStoreError.importedRecordImmutable(hkUUID)
        }
    }
}
