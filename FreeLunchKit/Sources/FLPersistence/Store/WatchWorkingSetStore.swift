// SPDX-License-Identifier: GPL-3.0-or-later
// Watch working set: phone-pushed food typeahead plus local records awaiting
// phone acknowledgement. The watch deliberately has no historical archive.
import FLCore
import Foundation
import SwiftData

public enum WatchOutboxKind: String, Sendable, Hashable, Codable, CaseIterable {
    case shot
    case meal
    case hungerEdit
}

/// A watch-created record that remains local until its phone acknowledgement.
public struct WatchOutboxItem: Sendable, Hashable, Identifiable {
    /// The acknowledgement handle, distinct from `subjectID` for hunger edits.
    public let id: UUID
    public let kind: WatchOutboxKind
    public let subjectID: UUID
    public let queuedAt: Date
    public let payload: Data

    public init(id: UUID, kind: WatchOutboxKind, subjectID: UUID, queuedAt: Date, payload: Data) {
        self.id = id
        self.kind = kind
        self.subjectID = subjectID
        self.queuedAt = queuedAt
        self.payload = payload
    }
}

public enum WatchWorkingSet {
    /// Maximum number of phone-ranked typeahead records retained on watch.
    public static let recentFoodCap = 200
}

/// A queued edit to a meal's optional pre-meal hunger value.
public struct WatchHungerEdit: Sendable, Hashable, Codable {
    public let mealID: UUID
    public let hunger: Int?
    public let editedAt: Date

    public init(mealID: UUID, hunger: Int?, editedAt: Date) {
        self.mealID = mealID
        self.hunger = hunger
        self.editedAt = editedAt
    }
}

/// Persistence operations that exist only on the watch's pruned working set.
@MainActor
public protocol WatchWorkingSetStore: AnyObject {
    /// Replaces the entire phone-ranked digest after deduplicating by food id.
    func replaceRecentFoods(_ digest: [RecentFoodSnapshotData]) throws
    /// Returns the current digest in the phone's rank order.
    func recentFoods() throws -> [RecentFoodSnapshotData]

    func enqueueShot(_ shot: ShotEventData, queuedAt: Date) throws
    func enqueueMeal(id: UUID, payload: Data, queuedAt: Date) throws
    @discardableResult
    func enqueueHungerEdit(_ edit: WatchHungerEdit) throws -> UUID
    /// Pending records, ordered by queue time and then acknowledgement handle.
    func outbox() throws -> [WatchOutboxItem]
    /// Idempotently prunes acknowledged records without changing the digest.
    func acknowledge(_ outboxIDs: [UUID]) throws
}

extension SwiftDataStore: WatchWorkingSetStore {
    public func replaceRecentFoods(_ digest: [RecentFoodSnapshotData]) throws {
        var foodIDs = Set<UUID>()
        var retained: [RecentFoodSnapshotData] = []
        for snapshot in digest where foodIDs.insert(snapshot.foodID).inserted {
            retained.append(snapshot)
            if retained.count == WatchWorkingSet.recentFoodCap { break }
        }

        let existing = try context.fetch(FetchDescriptor<RecentFoodSnapshot>())
        for snapshot in existing {
            context.delete(snapshot)
        }
        for (rank, snapshot) in retained.enumerated() {
            context.insert(RecentFoodSnapshot(
                foodID: snapshot.foodID,
                name: snapshot.name,
                lastPortionGrams: snapshot.lastPortionGrams,
                rank: rank
            ))
        }
        try commit()
    }

    public func recentFoods() throws -> [RecentFoodSnapshotData] {
        try context.fetch(FetchDescriptor<RecentFoodSnapshot>())
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.foodID.uuidString < rhs.foodID.uuidString
            }
            .map {
                RecentFoodSnapshotData(
                    foodID: $0.foodID,
                    name: $0.name,
                    lastPortionGrams: $0.lastPortionGrams
                )
            }
    }

    public func enqueueShot(_ shot: ShotEventData, queuedAt: Date) throws {
        guard try watchOutboxRecord(id: shot.id) == nil else {
            throw FreeLunchStoreError.duplicateID(shot.id)
        }
        let payload = try encodeWatchOutboxPayload(shot)
        context.insert(WatchOutboxRecord(
            id: shot.id,
            kind: .shot,
            subjectID: shot.id,
            queuedAt: queuedAt,
            payload: payload
        ))
        try commit()
    }

    public func enqueueMeal(id: UUID, payload: Data, queuedAt: Date) throws {
        guard try watchOutboxRecord(id: id) == nil else {
            throw FreeLunchStoreError.duplicateID(id)
        }
        context.insert(WatchOutboxRecord(
            id: id,
            kind: .meal,
            subjectID: id,
            queuedAt: queuedAt,
            payload: payload
        ))
        try commit()
    }

    @discardableResult
    public func enqueueHungerEdit(_ edit: WatchHungerEdit) throws -> UUID {
        if let hunger = edit.hunger, !DomainScale.hunger.contains(hunger) {
            throw FreeLunchStoreError.invalidHunger(hunger)
        }
        let id = UUID()
        let payload = try encodeWatchOutboxPayload(edit)
        context.insert(WatchOutboxRecord(
            id: id,
            kind: .hungerEdit,
            subjectID: edit.mealID,
            queuedAt: edit.editedAt,
            payload: payload
        ))
        try commit()
        return id
    }

    public func outbox() throws -> [WatchOutboxItem] {
        try context.fetch(FetchDescriptor<WatchOutboxRecord>())
            .sorted { lhs, rhs in
                if lhs.queuedAt != rhs.queuedAt { return lhs.queuedAt < rhs.queuedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .compactMap {
                guard let kind = $0.kind else { return nil }
                return WatchOutboxItem(
                    id: $0.id,
                    kind: kind,
                    subjectID: $0.subjectID,
                    queuedAt: $0.queuedAt,
                    payload: $0.payload
                )
            }
    }

    public func acknowledge(_ outboxIDs: [UUID]) throws {
        let acknowledged = Set(outboxIDs)
        guard !acknowledged.isEmpty else { return }
        let records = try context.fetch(FetchDescriptor<WatchOutboxRecord>())
        let matched = records.filter { acknowledged.contains($0.id) }
        guard !matched.isEmpty else { return }
        for record in matched {
            context.delete(record)
        }
        try commit()
    }

    private func watchOutboxRecord(id: UUID) throws -> WatchOutboxRecord? {
        var descriptor = FetchDescriptor<WatchOutboxRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

@MainActor
private func encodeWatchOutboxPayload<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    return try encoder.encode(value)
}
