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
        /// Seed one synthetic plate logged at this time yesterday, so a
        /// move into yesterday has a non-empty day to join.
        static let seedLoggedYesterday = "-FLUITestSeedLoggedYesterday"
        static let seedTimeline = "-FLUITestSeedTimeline"
    }

    private(set) var flow = PlateFlow()
    private(set) var meals: [MealEntryData] = []
    private(set) var foods: [FoodItemData] = []
    private(set) var loggedToday: NutritionTotals = .zero
    private(set) var target: DailyTarget?
    /// The weigh-as-you-go session of each open plate (spec §2). In memory
    /// only: it ends when the plate closes or is logged.
    private(set) var scaleSessions: [UUID: PlateScaleSession] = [:]
    /// The last change of a logged plate's time, shown on that plate until
    /// it closes (spec §2 acceptance #8: both days' totals after the move).
    private(set) var lastMove: LoggedAtMoveSummary?
    var errorMessage: String?

    private(set) var timelineShots: [ShotEventData] = []
    private(set) var timelineWeights: [CorrectedWeightSample] = []
    private(set) var timelineEffects: [SideEffectEntryData] = []
    private(set) var timelineJournal: [JournalEntryData] = []
    private(set) var timelinePlannedShots: [PlannedShotData] = []
    private(set) var timelinePlannedMeals: [PlannedMealData] = []
    private(set) var markedDays: Set<Date> = []
    private(set) var intakeEvidence: [Date: DayIntakeEvidence] = [:]
    private(set) var trendPoints: [TrendPoint] = []
    private(set) var nextDose: NextDoseStatus?
    private var energyCoordinator: EnergyRecomputeCoordinator<SwiftDataStore>?
    private var energyCoordinatorDay: Date?
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.freelunch.nutrition"
    private static let historyDays = 30
    private let store: SwiftDataStore?
    private let service: PlateLifecycleService?
    private let calendar: Calendar

    init(arguments: [String] = ProcessInfo.processInfo.arguments, calendar: Calendar = .current) {
        self.calendar = calendar
        let inMemory = arguments.contains(LaunchArgument.inMemoryStore)
        let location: FreeLunchStoreLocation = inMemory ? .inMemory : .applicationDefault
        do {
            let store = try SwiftDataStore.phone(at: location)
            self.store = store
            service = PlateLifecycleService(store: store)
            let now = Date()
            energyCoordinator = EnergyRecomputeCoordinator(store: store, calendar: calendar,
                ownSourceBundleID: ownBundleID,
                today: now, historyFrom: calendar.date(byAdding: .day, value: -Self.historyDays, to: now)!)
            energyCoordinatorDay = calendar.startOfDay(for: now)
        } catch {
            store = nil
            service = nil
            errorMessage = "Couldn't open the food log: \(error)"
            return
        }
        // The bundled food seed (spec §11), on every launch: the loader adds
        // only the entries the store lacks. UI tests' in-memory stores skip
        // it so their synthetic catalog stays exact. A failed load leaves
        // the log usable, without the seed.
        if !inMemory, let store {
            do {
                try FoodSeedLoader.applyBundled(to: store)
            } catch {
                errorMessage = "Couldn't load the built-in foods: \(error)"
            }
        }
        if arguments.contains(LaunchArgument.seedDraft) {
            seedSyntheticDraft()
        }
        if arguments.contains(LaunchArgument.seedFoods) {
            seedSyntheticFoods()
        }
        if arguments.contains(LaunchArgument.seedLoggedYesterday) {
            seedSyntheticLoggedYesterday()
        }
        if arguments.contains(LaunchArgument.seedTimeline) { seedSyntheticTimeline() }
        reload()
    }

    // MARK: Reading

    var drafts: [MealEntryData] {
        meals.filter { $0.state == .draft }
    }

    var timeline: TimelineFeed {
        TimelineFeed.build(now: Date(), calendar: calendar, meals: meals, shots: timelineShots,
            weights: timelineWeights, effects: timelineEffects, journal: timelineJournal,
            plannedShots: timelinePlannedShots, plannedMeals: timelinePlannedMeals, markedDays: markedDays)
    }

    func glyph(for day: Date) -> TimelineGlyph {
        switch DayCompleteness.intake(intakeEvidence[day] ?? DayIntakeEvidence()) {
        case .complete: .complete
        case .incomplete(.markedDidNotTrack): .markedNotTracked
        case .incomplete(.nothingLogged): .empty
        }
    }

    func toggleDidNotTrack(day: Date) {
        perform {
            let now = Date()
            if energyCoordinatorDay != calendar.startOfDay(for: now), let store {
                energyCoordinator = EnergyRecomputeCoordinator(store: store, calendar: calendar,
                    ownSourceBundleID: ownBundleID, today: now,
                    historyFrom: calendar.date(byAdding: .day, value: -Self.historyDays, to: now)!)
                energyCoordinatorDay = calendar.startOfDay(for: now)
            }
            guard let energyCoordinator else { return }
            defer { reload() }
            if markedDays.contains(calendar.startOfDay(for: day)) {
                try energyCoordinator.unmarkDidNotTrack(day: day)
            } else {
                try energyCoordinator.markDidNotTrack(day: day)
            }
        }
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
        lastMove = nil
        flow.open(plateID: meal.id)
    }

    func closePlate() {
        flow.closePlate()
        lastMove = nil
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
    /// `at == nil` is the one-tap default, now; an earlier time logs the
    /// plate late (spec §2 "Log"), and the sheet then speaks of that day
    /// with that day's totals and target. A future time is refused.
    func log(mealID: UUID, at chosen: Date? = nil) {
        perform {
            guard let service else { return }
            // The plate is committed before the day's totals are read, so
            // refresh even if that read throws: the screens never show a
            // logged plate as a draft. (No post-log sheet then; the error
            // alert says why.)
            defer { reload() }
            let logged = try service.logPlate(mealID: mealID, at: chosen, calendar: calendar)
            scaleSessions[mealID] = nil
            let day = logged.day.day
            flow.didLog(PostLogSummary(
                dayTotals: logged.day.totals,
                target: try dailyTarget(on: day),
                day: LoggedDay(loggedAt: day, now: Date(), calendar: calendar)
            ))
        }
    }

    // MARK: Late logging

    /// Edits a logged plate's `loggedAt` (spec §2: logged meals stay
    /// editable). The plate moves to the new day and both days' totals are
    /// recomputed from the store; the plate then shows both days' totals
    /// (`lastMove`). No post-log sheet: only Log fires it.
    func moveLoggedMeal(_ mealID: UUID, to loggedAt: Date) {
        perform {
            guard let service else { return }
            // As in `log`: the move is committed before the totals are read.
            defer { reload() }
            let move = try service.moveLoggedMeal(mealID: mealID, to: loggedAt, calendar: calendar)
            let now = Date()
            lastMove = LoggedAtMoveSummary(
                mealID: mealID,
                previousDay: LoggedDay(loggedAt: move.previousDay.day, now: now, calendar: calendar),
                previousTotals: move.previousDay.totals,
                currentDay: LoggedDay(loggedAt: move.newDay.day, now: now, calendar: calendar),
                currentTotals: move.newDay.totals
            )
        }
    }

    /// The move readout for `mealID`, if its time was just changed.
    func moveSummary(for mealID: UUID) -> LoggedAtMoveSummary? {
        lastMove?.mealID == mealID ? lastMove : nil
    }

    /// A HealthKit-imported plate is immutable (spec §1), so its time is
    /// shown but can't be changed.
    func canChangeLoggedAt(of meal: MealEntryData) -> Bool {
        meal.state == .logged && meal.source != .healthKitImport
    }

    /// "Yesterday, 12:30" for a logged plate; nil for a draft.
    func loggedAtText(for meal: MealEntryData) -> String? {
        guard meal.state == .logged, let loggedAt = meal.loggedAt else { return nil }
        let day = LoggedDay(loggedAt: loggedAt, now: Date(), calendar: calendar)
        // The clock time in the same calendar and time zone that named the day.
        let time = Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone)
        return "\(day.name), \(loggedAt.formatted(time))"
    }

    func loggedDay(for date: Date, now: Date) -> LoggedDay {
        LoggedDay(loggedAt: date, now: now, calendar: calendar)
    }

    func sameTimeYesterday(now: Date) -> Date {
        LateLogTime.sameTimeYesterday(now: now, calendar: calendar)
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
            timelineShots = try store.shots()
            timelineWeights = try store.correctedWeightView()
            timelineEffects = try store.sideEffects()
            timelineJournal = try store.journalEntries()
            timelinePlannedShots = try store.plannedShots()
            timelinePlannedMeals = try store.plannedMeals()
            markedDays = try store.didNotTrackDays(calendar: calendar)
            trendPoints = try EnergyBinding.trendSeries(store: store, smoothing: store.energySettings().smoothing).points
            let profiles = try store.medicationProfiles(includingArchived: false)
            nextDose = NextDose.status(shots: timelineShots, activeProfile: profiles.first, now: now, calendar: calendar)
            let intake = try store.dayIntakes(through: now, calendar: calendar,
                ownSourceBundleID: ownBundleID, markedDidNotTrack: markedDays)
            intakeEvidence = Dictionary(uniqueKeysWithValues: intake.map { ($0.day, $0.evidence) })
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
        } catch LateLoggingError.loggedAtInFuture {
            errorMessage = "A plate can't be logged at a time that hasn't happened yet."
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func seedSyntheticTimeline() {
        perform {
            guard let store, let service else { return }
            let now = Date()
            try store.createPlannedMeal(PlannedMealData(plannedAt: calendar.date(byAdding: .day, value: 1, to: now)!, name: "Synthetic planned meal"))
            try store.createPlannedShot(PlannedShotData(plannedAt: calendar.date(byAdding: .day, value: 2, to: now)!))
            for offset in 1...8 {
                try store.createPlannedMeal(PlannedMealData(plannedAt: calendar.date(byAdding: .minute, value: offset * 10, to: now)!, name: "Synthetic upcoming \(offset)"))
            }
            for offset in [1, 2, 3] {
                let plate = try service.startDraft()
                try service.addAdHocItem(name: "Synthetic day \(offset)", quantity: Grams(100),
                    nutrition: NutritionValues(kcal: Kilocalories(100), protein: Grams(1), carbs: Grams(1), fat: Grams(1)), toMeal: plate.id)
                try service.logPlate(mealID: plate.id, at: calendar.date(byAdding: .day, value: -offset, to: now)!, calendar: calendar)
            }
            seedSyntheticDraft()
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

    private func seedSyntheticLoggedYesterday() {
        perform {
            guard let service else { return }
            let plate = try service.startDraft()
            try service.addAdHocItem(
                name: "Synthetic soup",
                quantity: Grams(300),
                nutrition: NutritionValues(kcal: Kilocalories(400), protein: Grams(20), carbs: Grams(50), fat: Grams(12)),
                toMeal: plate.id
            )
            try service.logPlate(
                mealID: plate.id,
                at: LateLogTime.sameTimeYesterday(now: Date(), calendar: calendar),
                calendar: calendar
            )
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
