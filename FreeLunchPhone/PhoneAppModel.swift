// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's plate-logging state: the store, the plate lifecycle service
// and the log flow (spec §2). Views read values from here and call its
// actions; every number they show comes from FLPlate's presentation types.
import FLCore
import FLEnergyCore
import FLPersistence
import FLPlate
import Foundation
import Observation

@MainActor
@Observable
final class PhoneAppModel {
    /// Launch arguments for UI tests. They never reach a shipping flow:
    /// without them the app opens its on-disk store as usual.
    enum LaunchArgument {
        /// Use a throwaway in-memory store.
        static let inMemoryStore = "-FLUITestInMemoryStore"
        /// Seed one draft plate with one synthetic ad-hoc item.
        static let seedDraft = "-FLUITestSeedDraft"
        /// Seed two synthetic catalog foods for the weighing-flow tests.
        static let seedFoods = "-FLUITestSeedFoods"
    }

    private(set) var flow = PlateFlow()
    private(set) var meals: [MealEntryData] = []
    private(set) var foods: [FoodItemData] = []
    private(set) var loggedToday: NutritionTotals = .zero
    private(set) var target: DailyTarget?
    /// The weigh-as-you-go session of each open plate (spec §2). In memory
    /// only: it ends when the plate closes or is logged.
    private(set) var scaleSessions: [UUID: PlateScaleSession] = [:]
    var errorMessage: String?

    private let store: SwiftDataStore?
    private let service: PlateLifecycleService?
    private let calendar: Calendar

    init(arguments: [String] = ProcessInfo.processInfo.arguments, calendar: Calendar = .current) {
        self.calendar = calendar
        let location: FreeLunchStoreLocation = arguments.contains(LaunchArgument.inMemoryStore)
            ? .inMemory
            : .applicationDefault
        do {
            let store = try SwiftDataStore.phone(at: location)
            self.store = store
            service = PlateLifecycleService(store: store)
        } catch {
            store = nil
            service = nil
            errorMessage = "Couldn't open the food log: \(error)"
            return
        }
        if arguments.contains(LaunchArgument.seedDraft) {
            seedSyntheticDraft()
        }
        if arguments.contains(LaunchArgument.seedFoods) {
            seedSyntheticFoods()
        }
        reload()
    }

    // MARK: Reading

    var drafts: [MealEntryData] {
        meals.filter { $0.state == .draft }
    }

    /// Logged meals in today's calendar day, newest first.
    var loggedTodayMeals: [MealEntryData] {
        let now = Date()
        return meals
            .filter { meal in
                guard meal.state == .logged, let loggedAt = meal.loggedAt else { return false }
                return calendar.isDate(loggedAt, inSameDayAs: now)
            }
            .sorted { ($0.loggedAt ?? .distantPast) > ($1.loggedAt ?? .distantPast) }
    }

    func meal(id: UUID) -> MealEntryData? {
        meals.first { $0.id == id }
    }

    func header(for meal: MealEntryData) -> PlateHeader {
        PlateHeader(plate: meal, loggedToday: loggedToday, target: target)
    }

    func rows(for meal: MealEntryData) -> [PlateItemRow] {
        meal.items
            .sorted(by: MealItemData.displayOrder)
            .map { PlateItemRow(item: $0, food: $0.foodID.flatMap(foodInfo(id:))) }
    }

    func foodInfo(id: UUID) -> PlateFoodInfo? {
        guard let food = foods.first(where: { $0.id == id }) else { return nil }
        return PlateFoodInfo(name: food.name, isLiquid: food.isLiquid, servings: food.servings)
    }

    func typeaheadRows(query: String) -> [TypeaheadRow] {
        let candidates = foods.map { food in
            TypeaheadFood(
                id: food.id,
                name: food.name,
                brand: food.brand,
                useCount: food.useCount,
                lastUsedAt: food.lastUsedAt,
                lastPortionGrams: food.lastPortionGrams,
                isArchived: food.archivedAt != nil
            )
        }
        return Typeahead.rows(query: query, foods: candidates, now: Date())
    }

    func isStale(_ meal: MealEntryData) -> Bool {
        DraftNudge.isStale(meal, now: Date())
    }

    // MARK: Flow

    /// The timeline's primary Log action: a new draft, opened.
    func startPlate() {
        perform {
            guard let service else { return }
            let draft = try service.startDraft()
            reload()
            flow.open(plateID: draft.id)
        }
    }

    func open(_ meal: MealEntryData) {
        flow.open(plateID: meal.id)
    }

    func closePlate() {
        flow.closePlate()
        scaleSessions.removeAll()
        reload()
    }

    func dismissPostLog() {
        flow.dismissPostLog()
    }

    // MARK: Plate actions

    func addCatalogItem(_ step: QuantityStep, to mealID: UUID) {
        guard let grams = step.resolvedGrams else { return }
        perform {
            // Add-then-weigh: a gram reading is `.scaleWeighed`, a picked
            // serving `.typed` (spec §2 "Weighing flows").
            try service?.addCatalogItem(
                foodID: step.foodID,
                quantity: grams,
                provenance: step.provenance,
                toMeal: mealID
            )
            reload()
        }
    }

    func addAdHocItem(name: String, grams: Grams, nutrition: NutritionValues, saveAsFood: Bool, to mealID: UUID) {
        perform {
            try service?.addAdHocItem(
                name: name,
                quantity: grams,
                nutrition: nutrition,
                provenance: .typed,
                toMeal: mealID,
                saveAsFoodID: saveAsFood ? UUID() : nil
            )
            reload()
        }
    }

    func setQuantity(_ grams: Grams, itemID: UUID) {
        perform {
            try service?.setItemQuantity(grams, itemID: itemID)
            reload()
        }
    }

    // MARK: Scale session (weigh-as-you-go)

    func scaleSession(for mealID: UUID) -> PlateScaleSession? {
        scaleSessions[mealID]
    }

    func startScaleSession(_ mode: ScaleSessionMode, on mealID: UUID) {
        scaleSessions[mealID] = PlateScaleSession(mode: mode)
    }

    func endScaleSession(on mealID: UUID) {
        scaleSessions[mealID] = nil
    }

    /// Turns one scale reading into a `.scaleWeighed` item of `foodID`.
    /// Returns nil when the item was added, or the prompt to re-enter the
    /// reading. A refused reading writes nothing and leaves the session's
    /// running total where it was (spec §2 acceptance #3).
    func addScaleReading(_ reading: Double, foodID: UUID, to mealID: UUID) -> String? {
        guard var session = scaleSessions[mealID] else { return "The scale session has ended." }
        guard let service else { return "The food log isn't available." }
        do {
            try session.add(reading: reading) { grams, provenance in
                try service.addCatalogItem(foodID: foodID, quantity: grams, provenance: provenance, toMeal: mealID)
            }
            scaleSessions[mealID] = session
            reload()
            return nil
        } catch let error as ScaleEntryError {
            return ScaleSessionText.prompt(for: error, mode: session.mode)
        } catch {
            return "Couldn't add the item: \(error)"
        }
    }

    func removeItem(id: UUID) {
        perform {
            try store?.removeItem(id: id)
            reload()
        }
    }

    func tapHunger(_ value: Int, on meal: MealEntryData) {
        perform {
            try service?.setHunger(HungerControl.tapped(value, current: meal.hunger), mealID: meal.id)
            reload()
        }
    }

    /// The explicit Log action: the only path from draft to logged. Pops
    /// the plate and presents the post-log sheet over the timeline.
    func log(mealID: UUID) {
        perform {
            guard let service else { return }
            let logged = try service.log(mealID: mealID)
            scaleSessions[mealID] = nil
            reload()
            let day = logged.loggedAt ?? Date()
            let dayTotals = try service.dayTotals(containing: day, calendar: calendar)
            flow.didLog(PostLogSummary(dayTotals: dayTotals, target: try dailyTarget(on: day)))
        }
    }

    // MARK: Private

    private func reload() {
        guard let store, let service else { return }
        do {
            meals = try store.meals()
            foods = try store.foods(includingArchived: true)
            let now = Date()
            loggedToday = try service.dayTotals(containing: now, calendar: calendar)
            target = try dailyTarget(on: now)
        } catch {
            errorMessage = "Couldn't read the food log: \(error)"
        }
    }

    private func dailyTarget(on day: Date) throws -> DailyTarget? {
        guard let breakdown = try store?.adoptedMacroBreakdown(on: day, calendar: calendar) else { return nil }
        return DailyTarget(
            kcal: breakdown.targetKcal,
            proteinG: breakdown.proteinG,
            carbsG: breakdown.carbsG,
            fatFloorG: breakdown.fatFloorG
        )
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func seedSyntheticFoods() {
        perform {
            guard let store else { return }
            try store.createFood(FoodItemData(
                name: "Synthetic oats",
                per100g: NutritionValues(kcal: Kilocalories(400), protein: Grams(10), carbs: Grams(60), fat: Grams(8)),
                origin: .custom
            ))
            try store.createFood(FoodItemData(
                name: "Synthetic yogurt",
                per100g: NutritionValues(kcal: Kilocalories(50), protein: Grams(4), carbs: Grams(5), fat: Grams(2)),
                origin: .custom
            ))
        }
    }

    private func seedSyntheticDraft() {
        perform {
            guard let service else { return }
            let draft = try service.startDraft()
            try service.addAdHocItem(
                name: "Synthetic toast",
                quantity: Grams(60),
                nutrition: NutritionValues(kcal: Kilocalories(250), protein: Grams(8), carbs: Grams(30), fat: Grams(10)),
                toMeal: draft.id
            )
        }
    }
}
