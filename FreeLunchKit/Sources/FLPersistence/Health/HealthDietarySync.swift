// SPDX-License-Identifier: GPL-3.0-or-later
// Anchored dietary mirror and best-effort phone exports.
import FLCore
import Foundation

@MainActor
public final class HealthDietarySync {
    /// The types the dietary lane asks for: it reads and writes dietary energy.
    public static let accessTypes: Set<HealthDataType> = [.dietaryEnergyConsumed]
    /// Samples per anchored-query page during a backfill.
    public static let defaultPageLimit = 500

    /// The bundle identifier Apple Health records as the source of this
    /// app's samples, as the adapter that writes them reports it.
    public var ownSourceBundleID: String { health.ownSourceBundleID }

    let health: any HealthStoreAdapter
    let meals: any MealStore
    let dietary: any DietaryStore
    let anchors: any HealthAnchorStore
    let pageLimit: Int
    /// The pass in progress, which an overlapping `sync` joins.
    private var running: Task<HealthSyncResult, any Error>?

    public init(
        health: any HealthStoreAdapter,
        dietary: any DietaryStore,
        meals: any MealStore,
        anchors: any HealthAnchorStore,
        pageLimit: Int = HealthDietarySync.defaultPageLimit
    ) {
        precondition(pageLimit > 0, "pageLimit must be positive")
        self.health = health
        self.meals = meals
        self.dietary = dietary
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

    /// Asks for read and write access to the dietary lane's types. Only an
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
            let changes: HealthDietaryChanges
            do {
                changes = try await health.dietaryChanges(after: anchors.anchor(for: .dietaryEnergyConsumed), limit: pageLimit)
            } catch let error as HealthAccessError {
                return .degraded(error)
            }
            skipped += changes.unreadable
            for sample in changes.added {
                try dietary.upsertDietarySample(sample)
                upserted += 1
            }
            for hkUUID in changes.deleted {
                do {
                    try dietary.markDietarySampleDeletedInHK(hkUUID: hkUUID)
                    markedDeleted += 1
                } catch FreeLunchStoreError.notFound(let missing) where missing == hkUUID {
                    // Deleted before it was ever mirrored: nothing to flag.
                }
            }
            anchors.setAnchor(changes.anchor, for: .dietaryEnergyConsumed)
            if changes.isEmpty { break }
        }
        return .synced(upserted: upserted, markedDeleted: markedDeleted, skipped: skipped)
    }

    /// Local persistence succeeds independently of Health access.
    @discardableResult
    public func logMeal(id: UUID, at date: Date) async throws -> MealEntryData {
        let meal = try meals.logMeal(id: id, at: date)
        await writeMeal(meal)
        return meal
    }

    /// Call after persisting an edit, or after applying a watch meal on the phone.
    /// Save before deleting prior writes, so a failed save preserves the old sample.
    public func writeMeal(_ meal: MealEntryData) async {
        guard meal.state == .logged, meal.source != .healthKitImport,
              let date = meal.loggedAt else { return }
        do {
            let energy = try Kilocalories(validating: meal.items.reduce(0) { $0 + $1.nutrition.kcal })
            let saved = try await health.saveDietaryEnergy(energy, at: date, mealID: meal.id)
            try await health.deleteDietaryEnergy(mealID: meal.id, except: saved.hkUUID)
        } catch {
            // Health is a best-effort export. The native meal remains canonical.
        }
    }

    public func deleteMeal(id: UUID) async throws {
        try meals.deleteMeal(id: id)
        try? await health.deleteDietaryEnergy(mealID: id, except: nil)
    }

    private func forgetAnchor() async {
        if let running { _ = try? await running.value }
        anchors.setAnchor(nil, for: .dietaryEnergyConsumed)
    }
}
