// SPDX-License-Identifier: GPL-3.0-or-later
// Shared helpers for the FLPersistence suites. Every value is synthetic.
import FLCore
import Foundation
@testable import FLPersistence

/// Deterministic UUIDs: 00000000-0000-0000-0000-<n, 12 digits>.
func uid(_ n: Int) -> UUID {
    let digits = String(n)
    let padded = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
}

/// 2026-01-05 08:00:00 UTC.
let anchor = Date(timeIntervalSince1970: 1_767_600_000)

func at(day: Double = 0, hour: Double = 0) -> Date {
    anchor.addingTimeInterval(day * 86_400 + hour * 3_600)
}

let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

func nutrition(_ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double, fiber: Double? = nil) -> NutritionValues {
    NutritionValues(
        kcal: Kilocalories(kcal),
        protein: Grams(protein),
        carbs: Grams(carbs),
        fat: Grams(fat),
        fiber: fiber.map { Grams($0) }
    )
}

/// Bit-level equality, so "byte-identical" means exactly that.
func sameBits(_ lhs: NutritionValues, _ rhs: NutritionValues) -> Bool {
    lhs.kcal.bitPattern == rhs.kcal.bitPattern
        && lhs.proteinG.bitPattern == rhs.proteinG.bitPattern
        && lhs.carbsG.bitPattern == rhs.carbsG.bitPattern
        && lhs.fatG.bitPattern == rhs.fatG.bitPattern
        && lhs.fiberG?.bitPattern == rhs.fiberG?.bitPattern
}

@MainActor
func makeInMemoryStore() throws -> SwiftDataStore {
    try SwiftDataStore.phone(at: .inMemory)
}

/// A fresh store on a temporary file, and the URL to reopen it with.
func temporaryStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "fl-persistence-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "FreeLunch-test.store", directoryHint: .notDirectory)
}

func removeStore(at url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// Everything a store holds, read through the public API.
struct StoreGraph: Equatable {
    var foods: [FoodItemData]
    var recipes: [RecipeData]
    var meals: [MealEntryData]
    var aiRecords: [AIEstimationRecordData]
    var profiles: [MedicationProfileData]
    var shots: [ShotEventData]
    var sideEffects: [SideEffectEntryData]
    var plannedShots: [PlannedShotData]
    var plannedMeals: [PlannedMealData]
    var journal: [JournalEntryData]

    @MainActor
    init(_ store: some FreeLunchStore, aiRecordIDs: [UUID]) throws {
        foods = try store.foods(includingArchived: true)
        recipes = try store.recipes()
        meals = try store.meals()
        aiRecords = try aiRecordIDs.compactMap { try store.aiEstimation(id: $0) }
        profiles = try store.medicationProfiles(includingArchived: true)
        shots = try store.shots()
        sideEffects = try store.sideEffects()
        plannedShots = try store.plannedShots()
        plannedMeals = try store.plannedMeals()
        journal = try store.journalEntries()
    }
}
