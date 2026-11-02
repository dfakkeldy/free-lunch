// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #7: the watch keeps only its current digest and
// unacknowledged locally-created records. Every value is synthetic.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §1 acceptance #7: watch pruning")
struct WatchPruningTests {
    @Test("a digest retains its first 200 distinct foods in phone rank order")
    func digestCapAndRanks() throws {
        let store = try SwiftDataStore.watch(at: .inMemory)
        let digest = (1...250).map { number in
            RecentFoodSnapshotData(foodID: uid(number), name: "Food \(number)", lastPortionGrams: nil)
        }

        try store.replaceRecentFoods(digest)

        #expect(try store.recentFoods().count == 200)
        #expect(try store.rowCount(RecentFoodSnapshot.self) == 200)
        #expect(try store.recentFoods().map(\.foodID) == (1...200).map(uid))
        #expect(!(try store.recentFoods().contains { $0.foodID == uid(201) }))

        try store.replaceRecentFoods((1...200).map { number in
            RecentFoodSnapshotData(foodID: uid(number), name: "Food \(number)", lastPortionGrams: nil)
        })
        #expect(try store.recentFoods().count == 200)
        #expect(try store.rowCount(RecentFoodSnapshot.self) == 200)

        try store.replaceRecentFoods((1...199).map { number in
            RecentFoodSnapshotData(foodID: uid(number), name: "Food \(number)", lastPortionGrams: nil)
        })
        #expect(try store.recentFoods().count == 199)
        #expect(try store.rowCount(RecentFoodSnapshot.self) == 199)
    }

    @Test("a later digest replaces rather than accumulates food snapshots")
    func digestReplacement() throws {
        let store = try SwiftDataStore.watch(at: .inMemory)
        try store.replaceRecentFoods((1...200).map { number in
            RecentFoodSnapshotData(foodID: uid(number), name: "First \(number)", lastPortionGrams: nil)
        })
        let replacement = (501...505).map { number in
            RecentFoodSnapshotData(foodID: uid(number), name: "Second \(number)", lastPortionGrams: nil)
        }

        try store.replaceRecentFoods(replacement)

        #expect(try store.rowCount(RecentFoodSnapshot.self) == 5)
        #expect(try store.recentFoods() == replacement)
    }

    @Test("duplicate digest ids keep their first record and do not use a cap slot")
    func digestDeduplicatesBeforeCapping() throws {
        let store = try SwiftDataStore.watch(at: .inMemory)
        var digest = (1...100).map { number in
            RecentFoodSnapshotData(
                foodID: uid(number),
                name: number == 1 ? "First Food" : "Food \(number)",
                lastPortionGrams: number == 1 ? 85.5 : nil
            )
        }
        digest.append(RecentFoodSnapshotData(foodID: uid(1), name: "Later duplicate", lastPortionGrams: nil))
        digest += (101...200).map { number in
            RecentFoodSnapshotData(foodID: uid(number), name: "Food \(number)", lastPortionGrams: nil)
        }

        try store.replaceRecentFoods(digest)

        let foods = try store.recentFoods()
        #expect(foods.count == 200)
        #expect(foods.map(\.foodID) == (1...200).map(uid))
        #expect(foods.first?.name == "First Food")
        #expect(foods.first?.lastPortionGrams == 85.5)
        #expect(foods[1].lastPortionGrams == nil)
    }

    @Test("the outbox keeps watch records in queue order with their payloads")
    func outboxRecords() throws {
        let store = try SwiftDataStore.watch(at: .inMemory)
        let shot = ShotEventData(
            id: uid(601), takenAt: at(hour: 1), dose: Milligrams(2.5),
            medicationID: uid(602), source: .watch
        )
        let mealID = uid(603)
        let hungerEdit = WatchHungerEdit(mealID: uid(604), hunger: 3, editedAt: at(hour: 3))

        try store.enqueueShot(shot, queuedAt: at(hour: 1))
        try store.enqueueMeal(id: mealID, payload: Data([0xCA, 0xFE]), queuedAt: at(hour: 2))
        let hungerID = try store.enqueueHungerEdit(hungerEdit)

        let items = try store.outbox()
        #expect(items.count == 3)
        #expect(items.map(\.kind) == [.shot, .meal, .hungerEdit])
        #expect(items.map(\.subjectID) == [shot.id, mealID, hungerEdit.mealID])
        #expect(items.map(\.id) == [shot.id, mealID, hungerID])
        let decoded = try JSONDecoder().decode(ShotEventData.self, from: items[0].payload)
        #expect(decoded == shot)
        #expect(decoded.doseMg == 2.5)
        #expect(try store.rowCount(WatchOutboxRecord.self) == 3)
    }

    @Test("acknowledgements prune only matched outbox records and are idempotent")
    func acknowledgementsPruneOutboxOnly() throws {
        let store = try SwiftDataStore.watch(at: .inMemory)
        try store.replaceRecentFoods((1...200).map { number in
            RecentFoodSnapshotData(foodID: uid(number), name: "Food \(number)", lastPortionGrams: nil)
        })
        let shot = ShotEventData(id: uid(701), takenAt: at(hour: 1), dose: Milligrams(2.5), medicationID: uid(702), source: .watch)
        let mealID = uid(703)
        try store.enqueueShot(shot, queuedAt: at(hour: 1))
        try store.enqueueMeal(id: mealID, payload: Data([1, 2, 3]), queuedAt: at(hour: 2))
        let hungerID = try store.enqueueHungerEdit(WatchHungerEdit(mealID: uid(704), hunger: 4, editedAt: at(hour: 3)))

        try store.acknowledge([shot.id, hungerID])
        #expect(try store.outbox().map(\.id) == [mealID])
        #expect(try store.rowCount(WatchOutboxRecord.self) == 1)
        #expect(try store.rowCount(RecentFoodSnapshot.self) == 200)

        try store.acknowledge([mealID])
        #expect(try store.outbox().isEmpty)
        #expect(try store.rowCount(WatchOutboxRecord.self) == 0)
        try store.acknowledge([mealID, uid(999)])
        #expect(try store.outbox().isEmpty)
        #expect(try store.rowCount(WatchOutboxRecord.self) == 0)
        #expect(try store.rowCount(RecentFoodSnapshot.self) == 200)
    }

    @Test("refused outbox writes leave its rows unchanged and nil hunger clears")
    func outboxRefusalsAreAtomic() throws {
        let store = try SwiftDataStore.watch(at: .inMemory)
        let shot = ShotEventData(id: uid(801), takenAt: at(), dose: Milligrams(2.5), medicationID: uid(802), source: .watch)
        try store.enqueueShot(shot, queuedAt: at())

        #expect(throws: FreeLunchStoreError.duplicateID(shot.id)) {
            try store.enqueueShot(shot, queuedAt: at(hour: 1))
        }
        #expect(throws: FreeLunchStoreError.invalidHunger(0)) {
            try store.enqueueHungerEdit(WatchHungerEdit(mealID: uid(803), hunger: 0, editedAt: at(hour: 1)))
        }
        #expect(throws: FreeLunchStoreError.invalidHunger(6)) {
            try store.enqueueHungerEdit(WatchHungerEdit(mealID: uid(804), hunger: 6, editedAt: at(hour: 1)))
        }
        #expect(try store.rowCount(WatchOutboxRecord.self) == 1)

        let clearingID = try store.enqueueHungerEdit(WatchHungerEdit(mealID: uid(805), hunger: nil, editedAt: at(hour: 2)))
        #expect(try store.outbox().map(\.id) == [shot.id, clearingID])
        #expect(try store.rowCount(WatchOutboxRecord.self) == 2)
    }

    @Test("a file-backed watch working set survives reload and later acknowledgement")
    func coldReload() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let shot = ShotEventData(id: uid(901), takenAt: at(hour: 1), dose: Milligrams(2.5), medicationID: uid(902), source: .watch)
        let digest = (1...3).map { number in
            RecentFoodSnapshotData(foodID: uid(number), name: "Food \(number)", lastPortionGrams: nil)
        }

        do {
            let store = try SwiftDataStore.watch(at: .file(url))
            try store.replaceRecentFoods(digest)
            try store.enqueueShot(shot, queuedAt: at(hour: 1))
        }

        do {
            let reopened = try SwiftDataStore.watch(at: .file(url))
            #expect(try reopened.recentFoods() == digest)
            #expect(try reopened.outbox().map(\.id) == [shot.id])
            try reopened.acknowledge([shot.id])
        }

        let acknowledged = try SwiftDataStore.watch(at: .file(url))
        #expect(try acknowledged.recentFoods() == digest)
        #expect(try acknowledged.outbox().isEmpty)
    }
}
