// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §9 acceptance #4 at the protocol level, over the in-memory link:
// outbox → ack → prune, the 200-food digest cap, and the digest's rank
// order surviving the wire. (That rank order is §2's frequency order is
// pinned in FLPlateTests against the typeahead fixture.) Then convergence:
// dropped, duplicated and lost transfers, and rebuilt sync objects over the
// same stores, all settle with every record applied once and nothing left
// in the outbox. No clocks or sleeps: the link moves only when told.
// Every value is synthetic.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

/// An in-memory phone canonical store stand-in: an upsert keyed by the
/// record id, counting every call so tests can tell "applied twice into one
/// row" from "applied once".
@MainActor
final class RecordingApplier: WatchOutboxApplying {
    private(set) var rows: [UUID: WatchOutboxItem] = [:]
    private(set) var upsertCalls = 0
    /// Ids whose next upsert fails, once each.
    var failNext: Set<UUID> = []

    struct Refused: Error, Equatable {
        let id: UUID
    }

    func upsert(_ item: WatchOutboxItem) throws {
        upsertCalls += 1
        if failNext.remove(item.id) != nil {
            throw Refused(id: item.id)
        }
        rows[item.id] = item
    }
}

/// The real phone store as the applier: shots upsert by id through the
/// public store API, so duplicate deliveries are checked against SwiftData
/// rows rather than a dictionary.
@MainActor
final class ShotStoreApplier: WatchOutboxApplying {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    func upsert(_ item: WatchOutboxItem) throws {
        guard item.kind == .shot else { return }
        let shot = try JSONDecoder().decode(ShotEventData.self, from: item.payload)
        if try store.shot(id: shot.id) == nil {
            try store.createShot(shot)
        } else {
            try store.updateShot(shot)
        }
    }
}

/// Keeps both coordinators alive for a test (transports hold their
/// receivers weakly, as the app's long-lived models will), and rebuilds
/// either side to model a relaunch.
@MainActor
final class SyncHarness {
    let link = InMemoryWatchSyncLink()
    let applier: any WatchOutboxApplying
    private(set) var watchStore: SwiftDataStore
    private(set) var watch: WatchSyncCoordinator
    private(set) var phone: PhoneSyncCoordinator?

    init(watchStore: SwiftDataStore, applier: any WatchOutboxApplying = RecordingApplier(), phoneRunning: Bool = true) {
        self.watchStore = watchStore
        self.applier = applier
        watch = WatchSyncCoordinator(store: watchStore, transport: link.watch)
        if phoneRunning { launchPhone() }
    }

    convenience init() throws {
        self.init(watchStore: try SwiftDataStore.watch(at: .inMemory))
    }

    var recorder: RecordingApplier { applier as! RecordingApplier }

    func launchPhone() {
        phone = PhoneSyncCoordinator(transport: link.phone, applier: applier)
    }

    func relaunchWatch(store: SwiftDataStore? = nil) {
        if let store { watchStore = store }
        watch = WatchSyncCoordinator(store: watchStore, transport: link.watch)
    }
}

@MainActor
@Suite("Spec §9 acceptance #4: sync spine")
struct WatchSyncSpineTests {
    let medicationID = uid(9_000)

    func shot(_ n: Int) -> ShotEventData {
        ShotEventData(id: uid(n), takenAt: at(hour: Double(n % 24)), dose: Milligrams(2.5), medicationID: medicationID, source: .watch)
    }

    func food(_ n: Int) -> RecentFoodSnapshotData {
        RecentFoodSnapshotData(foodID: uid(n), name: "Food \(n)", lastPortionGrams: Double(n))
    }

    /// Queues a shot, a meal and a hunger edit; returns their outbox ids.
    func enqueueThree(_ store: SwiftDataStore, base: Int = 100) throws -> [UUID] {
        try store.enqueueShot(shot(base), queuedAt: at(hour: 1))
        try store.enqueueMeal(id: uid(base + 1), payload: Data([0xF0, 0x0D]), queuedAt: at(hour: 2))
        let hungerID = try store.enqueueHungerEdit(WatchHungerEdit(mealID: uid(base + 1), hunger: 3, editedAt: at(hour: 3)))
        return [uid(base), uid(base + 1), hungerID]
    }

    // MARK: Acceptance #4

    @Test("outbox → ack → prune: records reach the phone and leave the watch only on their ack")
    func outboxAckPrune() throws {
        let h = try SyncHarness()
        let ids = try enqueueThree(h.watchStore)

        try h.watch.sendOutbox()
        #expect(h.link.queuedCount(to: .phone) == 3)
        #expect(h.link.watch.queuedOutboxIDs == Set(ids))
        // Sending again while the transfers are still queued adds nothing.
        try h.watch.sendOutbox()
        #expect(h.link.queuedCount(to: .phone) == 3)

        // The phone applies all three; until the acks land, nothing prunes.
        for _ in 0..<3 { h.link.deliverNext(to: .phone) }
        #expect(Set(h.recorder.rows.keys) == Set(ids))
        #expect(try h.watchStore.outbox().map(\.id) == ids)
        #expect(try h.watch.pendingCount() == 3)
        #expect(h.link.queuedCount(to: .watch) == 3)

        // Each ack prunes exactly its record.
        h.link.deliverNext(to: .watch)
        #expect(try h.watchStore.outbox().map(\.id) == Array(ids.dropFirst()))
        h.link.pump()
        #expect(try h.watchStore.outbox().isEmpty)
        #expect(try h.watchStore.rowCount(WatchOutboxRecord.self) == 0)
        #expect(h.recorder.rows[ids[0]]?.kind == .shot)
        #expect(h.recorder.rows[ids[2]]?.subjectID == uid(101))
        #expect(h.link.receiveErrors.isEmpty)
    }

    @Test("the outbox crosses the wire byte for byte")
    func payloadFidelity() throws {
        let h = try SyncHarness()
        _ = try enqueueThree(h.watchStore)
        let sent = try h.watchStore.outbox()

        try h.watch.sendOutbox()
        h.link.pump()

        #expect(sent.map { h.recorder.rows[$0.id] } == sent)
        let payload = try #require(h.recorder.rows[uid(100)]).payload
        #expect(try JSONDecoder().decode(ShotEventData.self, from: payload) == shot(100))
    }

    @Test("a digest of 250 foods lands as the first 200, in the phone's order")
    func digestCapAndOrder() throws {
        let h = try SyncHarness()
        // Deliberately not in id order, so rank order cannot pass by accident.
        let ranked = (1...250).map { food(($0 * 37) % 251) }
        let nextDose = WatchNextDoseData(medicationID: medicationID, medicationName: "Tirzepatide", doseMg: 2.5, nextDoseAt: at(day: 3))
        let today = WatchTodayRemainingData(
            day: at(),
            consumed: WatchMacroValues(kcal: 900, proteinG: 70, carbsG: 80, fatG: 30),
            target: WatchMacroValues(kcal: 1_800, proteinG: 140, carbsG: 170, fatG: 50)
        )

        try h.phone?.publish(WatchDigestData(generatedAt: at(hour: 1), recentFoods: ranked, nextDose: nextDose, todayRemaining: today))
        h.link.pump()

        #expect(try h.watchStore.recentFoods() == Array(ranked.prefix(WatchDigestData.recentFoodCap)))
        #expect(try h.watchStore.rowCount(RecentFoodSnapshot.self) == 200)
        #expect(h.watch.digest?.nextDose == nextDose)
        #expect(h.watch.digest?.todayRemaining?.remaining?.kcal == 900)
    }

    @Test("a newer digest replaces the rows; an older one is ignored")
    func digestLatestWins() throws {
        let h = try SyncHarness()

        // Two publishes before delivery: only the latest reaches the watch.
        try h.phone?.publish(WatchDigestData(generatedAt: at(hour: 1), recentFoods: (1...5).map(food)))
        try h.phone?.publish(WatchDigestData(generatedAt: at(hour: 2), recentFoods: (11...13).map(food)))
        h.link.pump()
        #expect(try h.watchStore.recentFoods() == (11...13).map(food))

        try h.watch.receive(digest: WatchDigestData(generatedAt: at(hour: 1), recentFoods: (1...5).map(food)))
        #expect(try h.watchStore.recentFoods() == (11...13).map(food))
        #expect(h.watch.digest?.generatedAt == at(hour: 2))
    }

    // MARK: Convergence

    @Test("dropped outbox transfers are resent on the next activation")
    func droppedOutbox() throws {
        let h = try SyncHarness()
        let ids = try enqueueThree(h.watchStore)

        try h.watch.sendOutbox()
        h.link.dropNext(to: .phone, count: 2)
        h.link.pump()
        #expect(Set(h.recorder.rows.keys) == [ids[2]])
        #expect(try h.watchStore.outbox().map(\.id) == Array(ids.prefix(2)))

        try h.watch.activate()
        h.link.pump()
        #expect(Set(h.recorder.rows.keys) == Set(ids))
        #expect(try h.watchStore.outbox().isEmpty)
    }

    @Test("lost acks leave records queued; the retry reapplies as an upsert and prunes")
    func droppedAcks() throws {
        let h = try SyncHarness()
        let ids = try enqueueThree(h.watchStore)

        try h.watch.sendOutbox()
        h.link.dropNext(to: .watch, count: 3)
        h.link.pump()
        #expect(h.recorder.rows.count == 3)
        #expect(try h.watchStore.outbox().map(\.id) == ids)

        try h.watch.activate()
        h.link.pump()
        #expect(h.recorder.upsertCalls == 6)
        #expect(h.recorder.rows.count == 3)
        #expect(try h.watchStore.outbox().isEmpty)
    }

    @Test("duplicated deliveries in both directions apply into one row each")
    func duplicates() throws {
        let h = try SyncHarness()
        let ids = try enqueueThree(h.watchStore)

        try h.watch.sendOutbox()
        h.link.duplicateNext(to: .phone, count: 3)
        h.link.duplicateNext(to: .watch, count: 6)
        h.link.pump()

        #expect(h.recorder.upsertCalls == 6)
        #expect(Set(h.recorder.rows.keys) == Set(ids))
        #expect(try h.watchStore.outbox().isEmpty)
        #expect(h.link.receiveErrors.isEmpty)
    }

    @Test("a failed apply withholds the ack until a later retry succeeds")
    func failedApply() throws {
        let h = try SyncHarness()
        let ids = try enqueueThree(h.watchStore)
        h.recorder.failNext = [ids[1]]

        try h.watch.sendOutbox()
        h.link.pump()
        #expect(h.link.receiveErrors.count == 1)
        #expect(h.link.receiveErrors.first as? RecordingApplier.Refused == RecordingApplier.Refused(id: ids[1]))
        #expect(try h.watchStore.outbox().map(\.id) == [ids[1]])

        try h.watch.activate()
        h.link.pump()
        #expect(Set(h.recorder.rows.keys) == Set(ids))
        #expect(try h.watchStore.outbox().isEmpty)
    }

    @Test("killed midway: rebuilt sync objects over the same stores converge with no duplicates and no losses")
    func killedMidway() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let phoneStore = try makeInMemoryStore()
        try phoneStore.createMedicationProfile(MedicationProfileData(id: medicationID, known: .tirzepatide))
        let shots = (200..<206).map(shot)
        let nextDose = WatchNextDoseData(medicationID: medicationID, medicationName: "Tirzepatide", doseMg: 2.5, nextDoseAt: at(day: 7))

        let h = SyncHarness(watchStore: try SwiftDataStore.watch(at: .file(url)), applier: ShotStoreApplier(store: phoneStore))
        for (offset, shot) in shots.enumerated() {
            try h.watchStore.enqueueShot(shot, queuedAt: at(hour: Double(offset)))
        }
        try h.phone?.publish(WatchDigestData(generatedAt: at(hour: 1), recentFoods: (1...3).map(food), nextDose: nextDose))
        h.link.deliverDigest(to: .watch)
        try h.watch.sendOutbox()

        // Two shots reach the phone; one of their acks comes back, the other
        // is lost with everything still in flight.
        h.link.deliverNext(to: .phone)
        h.link.deliverNext(to: .phone)
        h.link.deliverNext(to: .watch)
        h.link.loseInFlight()
        #expect(try h.watchStore.outbox().count == 5)
        #expect(try phoneStore.shots().count == 2)

        // Both sides relaunch: the watch store reopened from its file, new
        // coordinators, the same link and phone store.
        h.relaunchWatch(store: try SwiftDataStore.watch(at: .file(url)))
        h.launchPhone()
        #expect(h.watch.digest == nil)

        try h.watch.activate()
        #expect(h.watch.digest?.nextDose == nextDose)
        h.link.pump()

        #expect(try phoneStore.shots() == shots)
        #expect(try h.watchStore.outbox().isEmpty)
        #expect(try h.watchStore.recentFoods() == (1...3).map(food))
        #expect(h.link.receiveErrors.isEmpty)
    }

    @Test("a relaunch before anything is delivered leaves the queued transfers alone, then converges")
    func relaunchWithTransfersQueued() throws {
        let h = SyncHarness(watchStore: try SwiftDataStore.watch(at: .inMemory), phoneRunning: false)
        let ids = try enqueueThree(h.watchStore)
        try h.watch.sendOutbox()

        // The watch relaunches while its transfers wait in the transport,
        // which keeps them; activation must not queue them a second time.
        h.relaunchWatch()
        try h.watch.activate()
        #expect(h.link.queuedCount(to: .phone) == 3)
        // Nothing moves toward a phone app that is not running.
        #expect(h.link.pump() == 0)

        // The phone starts later and catches up.
        h.launchPhone()
        h.link.pump()
        #expect(h.recorder.upsertCalls == 3)
        #expect(Set(h.recorder.rows.keys) == Set(ids))
        #expect(try h.watchStore.outbox().isEmpty)
    }

    @Test("a record queued after an earlier sync is sent and pruned on its own")
    func laterRecord() throws {
        let h = try SyncHarness()
        _ = try enqueueThree(h.watchStore)
        try h.watch.sendOutbox()
        h.link.pump()

        try h.watchStore.enqueueShot(shot(300), queuedAt: at(hour: 5))
        try h.watch.sendOutbox()
        #expect(h.link.queuedCount(to: .phone) == 1)
        h.link.pump()
        #expect(h.recorder.rows.count == 4)
        #expect(h.recorder.upsertCalls == 4)
        #expect(try h.watchStore.outbox().isEmpty)
    }

    // MARK: Wire format

    @Test("messages and digests round-trip; a newer format is refused")
    func codec() throws {
        let item = WatchOutboxItem(id: uid(1), kind: .hungerEdit, subjectID: uid(2), queuedAt: at(hour: 1), payload: Data([1, 2]))
        for message in [WatchSyncMessage.outbox(item), .ack([uid(3), uid(4)])] {
            #expect(try WatchSyncCodec.decodeMessage(WatchSyncCodec.encode(message)) == message)
        }
        let digest = WatchDigestData(
            generatedAt: at(hour: 2),
            recentFoods: [food(1), RecentFoodSnapshotData(foodID: uid(2), name: "Plain", lastPortionGrams: nil)],
            nextDose: WatchNextDoseData(medicationID: uid(5), medicationName: "Semaglutide", doseMg: 0.25, nextDoseAt: at(day: 7)),
            todayRemaining: WatchTodayRemainingData(day: at(), consumed: WatchMacroValues(kcal: 1, proteinG: 2, carbsG: 3, fatG: 4), target: nil)
        )
        #expect(try WatchSyncCodec.decodeDigest(WatchSyncCodec.encode(digest)) == digest)

        let future = Data(#"{"format":2,"body":{"ack":{"_0":[]}}}"#.utf8)
        #expect(throws: WatchSyncCodecError.unsupportedFormat(2)) {
            try WatchSyncCodec.decodeMessage(future)
        }
    }
}
