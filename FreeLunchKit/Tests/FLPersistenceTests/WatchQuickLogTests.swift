// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation
import Testing
@testable import FLPersistence

@MainActor private final class QuickState: WatchQuickLogStateStore {
    var anchor: WatchQuickLogAnchor?
    var draftID: UUID?
}
@MainActor private final class QuickClock {
    var now = at()
}
@MainActor private final class QuickApplier: WatchOutboxApplying {
    let store: SwiftDataStore
    init(_ store: SwiftDataStore) { self.store = store }
    func apply(_ item: WatchOutboxItem) throws {
        guard item.kind == .meal || item.kind == .mealAppend else { return }
        let meal = try JSONDecoder().decode(WatchMealPayload.self, from: item.payload)
        if try store.meal(id: meal.mealID) == nil {
            try store.createMeal(MealEntryData(id: meal.mealID, state: meal.state, createdAt: meal.createdAt,
                                               loggedAt: meal.loggedAt, hunger: meal.hunger, source: meal.source))
        }
        for food in meal.items {
            if try store.meal(id: meal.mealID)?.items.contains(where: { $0.id == food.itemID }) == false {
                try store.addItem(.catalog(id: food.itemID, foodID: food.foodID, quantity: Grams(food.quantityGrams)), toMeal: meal.mealID)
            }
        }
    }
}

@Suite @MainActor struct WatchQuickLogTests {
    @Test func quickLogAndUndo() throws {
        let watch = try SwiftDataStore.watch(at: .inMemory)
        let phone = try SwiftDataStore.phone(at: .inMemory)
        let foodID = uid(701)
        try phone.createFood(FoodItemData(id: foodID, name: "Synthetic", per100g: nutrition(200, 10, 20, 5), origin: .custom))
        let link = InMemoryWatchSyncLink()
        let sync = WatchSyncCoordinator(store: watch, transport: link.watch)
        let applier = QuickApplier(phone)
        let coordinator = PhoneSyncCoordinator(transport: link.phone, applier: applier, ledger: phone, now: { at() })
        let clock = QuickClock(), state = QuickState()
        let service = WatchQuickLogService(store: watch, sync: sync, state: state, clock: { clock.now })
        let cancelled = try service.tap(foodID: foodID, lastPortionGrams: 150)
        #expect(service.undo(cancelled))
        try sync.sendOutbox()
        #expect(link.queuedCount(to: .phone) == 0)
        let first = try service.tap(foodID: foodID, lastPortionGrams: 150)
        clock.now = at().addingTimeInterval(5)
        #expect(!service.undo(first))
        try service.flush()
        _ = link.pump()
        let mealID = try #require(state.anchor?.mealID)
        let meal = try #require(try phone.meal(id: mealID))
        #expect(meal.items.count == 1)
        #expect(meal.items[0].quantityGrams == 150)
        #expect(meal.items[0].nutrition.kcal == 300)
        clock.now = at().addingTimeInterval(9 * 60)
        _ = try service.tap(foodID: foodID, lastPortionGrams: 100)
        clock.now.addTimeInterval(5)
        try service.flush()
        _ = link.pump()
        #expect(try phone.meal(id: mealID)?.items.count == 2)
        clock.now = at().addingTimeInterval(20 * 60)
        _ = try service.tap(foodID: foodID, lastPortionGrams: 100)
        clock.now.addTimeInterval(5)
        try service.flush()
        #expect(state.anchor?.mealID != mealID)
        // A separate sequence pins the inclusive boundary through the service.
        let otherState = QuickState()
        let other = WatchQuickLogService(store: watch, sync: sync, state: otherState, clock: { clock.now })
        clock.now = at(day: 2)
        _ = try other.tap(foodID: foodID, lastPortionGrams: 100)
        try other.commitPending()
        let original = otherState.anchor?.mealID
        clock.now = at(day: 2).addingTimeInterval(600)
        _ = try other.tap(foodID: foodID, lastPortionGrams: 100)
        try other.commitPending()
        #expect(otherState.anchor?.mealID == original)
        clock.now.addTimeInterval(660)
        _ = try other.tap(foodID: foodID, lastPortionGrams: 100)
        try other.commitPending()
        #expect(otherState.anchor?.mealID != original)
        withExtendedLifetime(coordinator) {}
    }
    @Test func boundaryMarkerAndHunger() throws {
        #expect(WatchQuickLogRules.coalesces(lastTapAt: at(), tapAt: at().addingTimeInterval(600)))
        #expect(!WatchQuickLogRules.coalesces(lastTapAt: at(), tapAt: at().addingTimeInterval(601)))
        #expect(abs((WatchQuickLogRules.portion(lastPortionGrams: 100, steps: 1) ?? 0) - 110) < 0.000001)
        #expect(WatchQuickLogRules.portion(lastPortionGrams: 100, steps: -10) == nil)
        let store = try SwiftDataStore.watch(at: .inMemory), link = InMemoryWatchSyncLink()
        let sync = WatchSyncCoordinator(store: store, transport: link.watch), state = QuickState()
        let service = WatchQuickLogService(store: store, sync: sync, state: state, clock: { at() })
        try service.setHunger(3)
        let first = try #require(store.outbox().first)
        let payload = try JSONDecoder().decode(WatchMealPayload.self, from: first.payload)
        #expect(payload.state == .draft && payload.items.isEmpty && payload.hunger == 3)
        try service.setHunger(4)
        #expect(try store.outbox().contains { $0.kind == .hungerEdit && $0.subjectID == payload.mealID })
        service.clearDraft()
        let before = try store.outbox().count
        try service.setHunger(nil)
        #expect(try store.outbox().count == before)
        let marker = try service.marker()
        #expect(state.draftID == marker)
    }
}
