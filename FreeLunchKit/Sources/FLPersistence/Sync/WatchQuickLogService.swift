// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation

public struct WatchQuickLogAnchor: Codable, Sendable, Equatable {
    public var mealID: UUID
    public var lastTapAt: Date
    public init(mealID: UUID, lastTapAt: Date) {
        self.mealID = mealID
        self.lastTapAt = lastTapAt
    }
}

@MainActor public protocol WatchQuickLogStateStore: AnyObject {
    var anchor: WatchQuickLogAnchor? { get set }
    var draftID: UUID? { get set }
}

@MainActor public final class UserDefaultsWatchQuickLogState: WatchQuickLogStateStore {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "watchQuickLog") {
        self.defaults = defaults
        self.key = key
    }
    public var anchor: WatchQuickLogAnchor? {
        get { defaults.data(forKey: key + ".anchor").flatMap { try? JSONDecoder().decode(WatchQuickLogAnchor.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key + ".anchor") }
    }
    public var draftID: UUID? {
        get { defaults.string(forKey: key + ".draft").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: key + ".draft") }
    }
}

/// Holds food taps locally for the undo interval before sending immutable records.
@MainActor public final class WatchQuickLogService {
    private struct Pending {
        let id: UUID
        let foodID: UUID
        let grams: Double
        let at: Date
    }
    private let store: any WatchWorkingSetStore
    private let sync: WatchSyncCoordinator
    private let state: any WatchQuickLogStateStore
    private let clock: () -> Date
    private var pending: [Pending] = []
    public private(set) var lastError: (any Error)?

    public init(store: any WatchWorkingSetStore, sync: WatchSyncCoordinator,
                state: any WatchQuickLogStateStore = UserDefaultsWatchQuickLogState(),
                clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.sync = sync
        self.state = state
        self.clock = clock
    }

    @discardableResult public func tap(foodID: UUID, lastPortionGrams: Double, steps: Int = 0) throws -> UUID {
        try flush()
        guard let grams = WatchQuickLogRules.portion(lastPortionGrams: lastPortionGrams, steps: steps) else {
            throw QuickLogError.invalidPortion
        }
        let item = Pending(id: UUID(), foodID: foodID, grams: grams, at: clock())
        pending.append(item)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            do { try self.flush() } catch { self.lastError = error }
        }
        return item.id
    }

    @discardableResult public func undo(_ itemID: UUID) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == itemID }),
              WatchQuickLogRules.canUndo(tapAt: pending[index].at, now: clock()) else { return false }
        pending.remove(at: index)
        return true
    }

    /// Call after a foreground transition, and retry after any reported error.
    public func flush() throws {
        let now = clock()
        while let item = pending.first, now.timeIntervalSince(item.at) >= WatchQuickLogRules.undoInterval {
            let previous = state.anchor
            let append = previous.map { WatchQuickLogRules.coalesces(lastTapAt: $0.lastTapAt, tapAt: item.at) } ?? false
            let mealID = append ? previous!.mealID : UUID()
            let payload = WatchMealPayload(mealID: mealID, state: .logged, source: .watchQuickLog,
                createdAt: item.at, loggedAt: item.at, hunger: nil,
                items: [.init(itemID: item.id, foodID: item.foodID, quantityGrams: item.grams)])
            let data = try JSONEncoder().encode(payload)
            if append { try store.enqueueMealAppend(id: item.id, mealID: mealID, payload: data, queuedAt: item.at) }
            else { try store.enqueueMeal(id: mealID, payload: data, queuedAt: item.at) }
            state.anchor = .init(mealID: mealID, lastTapAt: item.at)
            pending.removeFirst()
        }
        try sync.sendOutbox()
        lastError = nil
    }

    @discardableResult public func marker(hunger: Int? = nil) throws -> UUID {
        if let hunger, !DomainScale.hunger.contains(hunger) { throw QuickLogError.invalidHunger }
        let id = UUID(), now = clock()
        let payload = WatchMealPayload(mealID: id, state: .draft, source: .watchMarker,
                                       createdAt: now, loggedAt: nil, hunger: hunger, items: [])
        try store.enqueueMeal(id: id, payload: JSONEncoder().encode(payload), queuedAt: now)
        state.draftID = id
        try sync.sendOutbox()
        return id
    }

    public func setHunger(_ hunger: Int?) throws {
        if let hunger, !DomainScale.hunger.contains(hunger) { throw QuickLogError.invalidHunger }
        if let draft = state.draftID {
            try store.enqueueHungerEdit(.init(mealID: draft, hunger: hunger, editedAt: clock()))
            try sync.sendOutbox()
        } else { _ = try marker(hunger: hunger) }
    }

    /// The caller clears the watch-created draft after it is closed on the phone.
    public func clearDraft() { state.draftID = nil }
    public enum QuickLogError: Error { case invalidPortion, invalidHunger }
}
