// SPDX-License-Identifier: GPL-3.0-or-later
// The persisted home of the settings the energy engine reads (spec §3 trend
// α, adopted-target mode, day completeness; spec §6 smoothing control). Every
// value is synthetic.
//
// Cold reload means what a relaunch does: the store object goes away and a
// new one opens the same file on disk.
import FLCore
import FLEnergyCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

private typealias E = EnergyStoreFixture

@MainActor
@Suite("Energy settings: defaults and validation")
struct EnergySettingsDefaultsTests {
    @Test("a store with no saved settings reads the spec defaults")
    func defaults() throws {
        let store = try makeInMemoryStore()
        let settings = try store.energySettings()
        #expect(settings == .defaults)
        // Spec §3: α 0.10/day, adjustable 0.05-0.25.
        #expect(settings.smoothing.alpha == 0.10)
        #expect(TrendSmoothing.allowedAlphaRange == 0.05...0.25)
        // Spec §3 (decision 2026-08-01): suggest-only, weekly auto-adopt is opt-in.
        #expect(settings.adoptionMode == .suggestOnly)
        #expect(settings.rateGoal == .maintenance)
        #expect(settings.schedule == FormulaActivationSchedule())
        #expect(settings.schedule.latest == .builtinV1)
        #expect(try store.didNotTrackDays(calendar: E.calendar).isEmpty)
        // Reading creates nothing.
        #expect(try store.rowCount(EnergySettingsRecord.self) == 0)
    }

    @Test("the two entities' fields are exactly what the settings lane needs")
    func entityShapes() throws {
        let schema = Schema(versionedSchema: FreeLunchSchemaV2.self)
        let settings = try #require(schema.entities.first { $0.name == "EnergySettingsRecord" })
        let optionality = Dictionary(uniqueKeysWithValues: settings.attributes.map { ($0.name, $0.isOptional) })
        #expect(optionality == [
            "singletonKey": false, "trendAlpha": false, "rateGoalKgPerWeek": false,
            "adoptionModeRaw": false, "activationScheduleJSON": true
        ])
        #expect(settings.relationships.isEmpty)
        #expect(Set(settings.attributes.filter(\.isUnique).map(\.name)) == ["singletonKey"])

        let marks = try #require(schema.entities.first { $0.name == "DidNotTrackMark" })
        #expect(marks.attributes.map(\.name) == ["day"])
        #expect(marks.relationships.isEmpty)
        #expect(Set(marks.attributes.filter(\.isUnique).map(\.name)) == ["day"])
    }

    @Test("α is accepted across the closed range and refused outside it, leaving the store unchanged")
    func alphaBoundary() throws {
        let store = try makeInMemoryStore()
        for alpha in [0.05, 0.10, 0.15, 0.25] {
            try store.setTrendAlpha(alpha)
            #expect(try store.energySettings().smoothing.alpha == alpha)
        }
        try store.setTrendAlpha(0.15)
        for bad in [0.0, 0.049_999, 0.250_001, 1, -0.1, .nan, .infinity, -.infinity] {
            #expect(throws: EnergySettingsError.self) { try store.setTrendAlpha(bad) }
        }
        #expect(throws: EnergySettingsError.alphaOutOfRange(0.3)) { try store.setTrendAlpha(0.3) }
        #expect(try store.energySettings().smoothing.alpha == 0.15)
        #expect(try store.rowCount(EnergySettingsRecord.self) == 1)
    }

    @Test("a refused first write does not create the settings row")
    func refusedFirstWrite() throws {
        let store = try makeInMemoryStore()
        #expect(throws: EnergySettingsError.alphaOutOfRange(0.5)) { try store.setTrendAlpha(0.5) }
        #expect(throws: EnergySettingsError.invalidRateGoal(.infinity)) { try store.setRateGoal(kgPerWeek: .infinity) }
        #expect(throws: EnergySettingsError.self) { try store.setRateGoal(kgPerWeek: .nan) }
        #expect(try store.rowCount(EnergySettingsRecord.self) == 0)
        #expect(try store.energySettings() == .defaults)
    }

    @Test("writing one setting leaves every other at its default")
    func independentSettings() throws {
        let store = try makeInMemoryStore()
        try store.setRateGoal(kgPerWeek: -0.5)
        var expected = EnergySettings.defaults
        expected.rateGoal = E.rate(-0.5)
        #expect(try store.energySettings() == expected)

        try store.setAdoptionMode(.weeklyAutoAdopt)
        expected.adoptionMode = .weeklyAutoAdopt
        #expect(try store.energySettings() == expected)
        #expect(try store.rowCount(EnergySettingsRecord.self) == 1)
    }

    @Test("a row built from settings keeps every value, a non-default schedule included")
    func rowFromSettings() throws {
        let settings = EnergySettings(
            smoothing: try #require(TrendSmoothing(alpha: 0.2)),
            rateGoal: E.rate(-0.25),
            adoptionMode: .weeklyAutoAdopt,
            schedule: try FormulaActivationSchedule().activating(E.v2, from: E.day(12), calendar: E.calendar)
        )
        #expect(try EnergySettingsRecord(from: settings).asEnergySettings() == settings)
        #expect(try EnergySettingsRecord(from: .defaults).activationScheduleJSON == nil)
    }

    @Test("any finite rate goal is stored: the rails warn, they never block (spec §3)")
    func rateGoalIsNotClamped() throws {
        let store = try makeInMemoryStore()
        try store.setRateGoal(kgPerWeek: -1.5)
        #expect(try store.energySettings().rateGoal.kgPerWeek == -1.5)
    }

    @Test("activation is forward-only; a retroactive activation is refused and stores nothing")
    func activationForwardOnly() throws {
        let store = try makeInMemoryStore()
        try store.activateFormula(E.v2, from: E.noon(10), today: E.morning(10), calendar: E.calendar)
        let schedule = try store.energySettings().schedule
        #expect(schedule.activations.map(\.effectiveFrom) == [.distantPast, E.day(10)])
        #expect(schedule.formula(on: E.day(9), calendar: E.calendar) == .builtinV1)
        #expect(schedule.formula(on: E.day(10), calendar: E.calendar) == E.v2)

        #expect(throws: EnergySettingsError.retroactiveActivation(latestEffectiveFrom: E.day(10))) {
            try store.activateFormula(.builtinV1, from: E.day(9), today: E.day(8), calendar: E.calendar)
        }
        #expect(try store.energySettings().schedule == schedule)
    }

    @Test("an activation before today is refused, even from the default schedule, and stores nothing")
    func activationBeforeTodayRefused() throws {
        let store = try makeInMemoryStore()
        // Spec §3 "Versioning": switching applies forward only. Yesterday is
        // already rendered history.
        #expect(throws: EnergySettingsError.activationBeforeToday(today: E.day(25))) {
            try store.activateFormula(E.v2, from: E.noon(24), today: E.noon(25), calendar: E.calendar)
        }
        #expect(try store.energySettings() == .defaults)
        #expect(try store.rowCount(EnergySettingsRecord.self) == 0)

        // Today itself is forward.
        try store.activateFormula(E.v2, from: E.morning(25), today: E.noon(25), calendar: E.calendar)
        #expect(try store.energySettings().schedule.activations.map(\.effectiveFrom) == [.distantPast, E.day(25)])
    }

    @Test("marks are idempotent, normalized to the calendar day, and removable")
    func marks() throws {
        let store = try makeInMemoryStore()
        try store.markDidNotTrack(day: E.noon(3), calendar: E.calendar)
        try store.markDidNotTrack(day: E.morning(3), calendar: E.calendar)
        try store.markDidNotTrack(day: E.day(3), calendar: E.calendar)
        try store.markDidNotTrack(day: E.noon(5), calendar: E.calendar)
        #expect(try store.didNotTrackDays(calendar: E.calendar) == [E.day(3), E.day(5)])
        #expect(try store.rowCount(DidNotTrackMark.self) == 2)

        try store.unmarkDidNotTrack(day: E.morning(3), calendar: E.calendar)
        try store.unmarkDidNotTrack(day: E.day(9), calendar: E.calendar)  // not marked: no effect
        #expect(try store.didNotTrackDays(calendar: E.calendar) == [E.day(5)])
    }

    @Test("a mark is a calendar day: a time-zone change keeps it on that day, and it can still be removed")
    func marksAcrossTimeZones() throws {
        let store = try makeInMemoryStore()
        let east = try calendar(secondsFromGMT: 9 * 3_600)
        let west = try calendar(secondsFromGMT: -5 * 3_600)
        // Marked at 10:00 on 8 January in UTC+9 (01:00 UTC that day).
        let marked = try #require(east.date(from: DateComponents(year: 2026, month: 1, day: 8, hour: 10)))
        try store.markDidNotTrack(day: marked, calendar: east)
        let eastDay = east.startOfDay(for: marked)
        let westDay = try #require(west.date(from: DateComponents(year: 2026, month: 1, day: 8)))
        #expect(try store.didNotTrackDays(calendar: east) == [eastDay])
        #expect(try store.didNotTrackDays(calendar: west) == [westDay])

        // The engine reads it on 8 January in the new zone, not on the 7th.
        let key = try EnergyBinding.key(
            store: store, today: westDay.addingTimeInterval(12 * 3_600), historyFrom: westDay,
            calendar: west, weights: { _ in E.weights }
        )
        #expect(key.intake.map(\.day) == [westDay])
        #expect(key.intake.first?.evidence.markedDidNotTrack == true)

        // The same calendar day marked from the other zone is the same row.
        try store.markDidNotTrack(day: westDay.addingTimeInterval(20 * 3_600), calendar: west)
        #expect(try store.rowCount(DidNotTrackMark.self) == 1)

        try store.unmarkDidNotTrack(day: westDay.addingTimeInterval(9 * 3_600), calendar: west)
        #expect(try store.didNotTrackDays(calendar: east).isEmpty)
        #expect(try store.rowCount(DidNotTrackMark.self) == 0)
    }

    private func calendar(secondsFromGMT seconds: Int) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: seconds))
        return calendar
    }

    @Test("a damaged settings row is refused on load, not read as plausible settings")
    func damagedRowRefused() throws {
        let store = try makeInMemoryStore()
        try store.setRateGoal(kgPerWeek: -0.25)
        let row = try #require(try store.context.fetch(FetchDescriptor<EnergySettingsRecord>()).first)

        row.trendAlpha = 0.9
        #expect(throws: EnergySettingsError.invalidStoredSettings) { try store.energySettings() }
        row.trendAlpha = 0.10

        row.rateGoalKgPerWeek = .nan
        #expect(throws: EnergySettingsError.invalidStoredSettings) { try store.energySettings() }
        row.rateGoalKgPerWeek = -0.25

        row.adoptionModeRaw = "someFutureMode"
        #expect(throws: EnergySettingsError.invalidStoredSettings) { try store.energySettings() }
        row.adoptionModeRaw = AdoptionMode.suggestOnly.rawValue

        row.activationScheduleJSON = Data("not a schedule".utf8)
        #expect(throws: EnergySettingsError.invalidStoredSettings) { try store.energySettings() }
        // Activations out of order do not decode to a schedule.
        row.activationScheduleJSON = Data(#"{"activations":[]}"#.utf8)
        #expect(throws: EnergySettingsError.invalidStoredSettings) { try store.energySettings() }
        row.activationScheduleJSON = nil

        #expect(try store.energySettings().rateGoal.kgPerWeek == -0.25)
    }

    @Test("the watch store refuses every settings operation and stores nothing")
    func watchRefuses() throws {
        let watch = try SwiftDataStore.watch(at: .inMemory)
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("energySettings")) { try watch.energySettings() }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("setTrendAlpha")) { try watch.setTrendAlpha(0.2) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("setRateGoal")) { try watch.setRateGoal(kgPerWeek: -0.5) }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("setAdoptionMode")) {
            try watch.setAdoptionMode(.weeklyAutoAdopt)
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("setFormulaActivationSchedule")) {
            try watch.setFormulaActivationSchedule(FormulaActivationSchedule())
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("activateFormula")) {
            try watch.activateFormula(E.v2, from: E.day(1), today: E.day(1), calendar: E.calendar)
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("markDidNotTrack")) {
            try watch.markDidNotTrack(day: E.day(1), calendar: E.calendar)
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("unmarkDidNotTrack")) {
            try watch.unmarkDidNotTrack(day: E.day(1), calendar: E.calendar)
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("didNotTrackDays")) { try watch.didNotTrackDays(calendar: E.calendar) }
        #expect(try watch.rowCount(EnergySettingsRecord.self) == 0)
        #expect(try watch.rowCount(DidNotTrackMark.self) == 0)
    }
}

@MainActor
@Suite("Energy settings: cold reload round trips")
struct EnergySettingsColdReloadTests {
    /// Writes with `change` in one store object, drops it, and reads the
    /// settings and marks back from a new store object on the same file.
    private func coldReload(
        _ change: (SwiftDataStore) throws -> Void
    ) throws -> (settings: EnergySettings, marks: Set<Date>) {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        do {
            let store = try SwiftDataStore.phone(at: .file(url))
            try change(store)
        }
        let reopened = try SwiftDataStore.phone(at: .file(url))
        return (try reopened.energySettings(), try reopened.didNotTrackDays(calendar: E.calendar))
    }

    @Test("α survives a cold reload", arguments: [0.05, 0.125, 0.25])
    func alpha(alpha: Double) throws {
        let reloaded = try coldReload { try $0.setTrendAlpha(alpha) }
        #expect(reloaded.settings.smoothing.alpha == alpha)
        #expect(reloaded.settings.rateGoal == .maintenance)
        #expect(reloaded.settings.adoptionMode == .suggestOnly)
    }

    @Test("the rate goal survives a cold reload", arguments: [-0.75, 0, 0.25])
    func rateGoal(rate: Double) throws {
        let reloaded = try coldReload { try $0.setRateGoal(kgPerWeek: rate) }
        #expect(reloaded.settings.rateGoal.kgPerWeek == rate)
        #expect(reloaded.settings.smoothing == .standard)
    }

    @Test("the adoption mode survives a cold reload, including a switch back", arguments: AdoptionMode.allCases)
    func adoptionMode(mode: AdoptionMode) throws {
        let reloaded = try coldReload { store in
            try store.setAdoptionMode(.weeklyAutoAdopt)
            try store.setAdoptionMode(mode)
        }
        #expect(reloaded.settings.adoptionMode == mode)
    }

    @Test("the activation schedule survives a cold reload exactly, parameters and dates included")
    func schedule() throws {
        let user = EnergyFormulaVersion(
            name: "Synthetic user edit", origin: .userEdited,
            parameters: try #require(ExpenditureParameters(energyDensityKcalPerKg: 7_250.5))
        )
        let schedule = try FormulaActivationSchedule()
            .activating(E.v2, from: E.day(12), calendar: E.calendar)
            .activating(user, from: E.day(30), calendar: E.calendar)
        let reloaded = try coldReload { try $0.setFormulaActivationSchedule(schedule) }
        #expect(reloaded.settings.schedule == schedule)
        #expect(reloaded.settings.schedule.activations.first?.effectiveFrom == .distantPast)
        #expect(reloaded.settings.schedule.formula(on: E.day(31), calendar: E.calendar) == user)
    }

    @Test("an activation made through activateFormula survives a cold reload")
    func activation() throws {
        let reloaded = try coldReload { try $0.activateFormula(E.v2, from: E.noon(4), today: E.day(4), calendar: E.calendar) }
        #expect(reloaded.settings.schedule.latest == E.v2)
        #expect(reloaded.settings.schedule.activations.map(\.effectiveFrom) == [.distantPast, E.day(4)])
    }

    @Test("didn't-track marks survive a cold reload, and an unmark survives too")
    func marks() throws {
        let reloaded = try coldReload { store in
            try store.markDidNotTrack(day: E.noon(2), calendar: E.calendar)
            try store.markDidNotTrack(day: E.noon(7), calendar: E.calendar)
            try store.markDidNotTrack(day: E.noon(9), calendar: E.calendar)
            try store.unmarkDidNotTrack(day: E.day(7), calendar: E.calendar)
        }
        #expect(reloaded.marks == [E.day(2), E.day(9)])
        #expect(reloaded.settings == .defaults)
    }

    @Test("every setting together survives a cold reload on the same file")
    func everything() throws {
        let reloaded = try coldReload { store in
            try store.setTrendAlpha(0.2)
            try store.setRateGoal(kgPerWeek: -0.5)
            try store.setAdoptionMode(.weeklyAutoAdopt)
            try store.activateFormula(E.v2, from: E.day(10), today: E.day(10), calendar: E.calendar)
            try store.markDidNotTrack(day: E.day(3), calendar: E.calendar)
        }
        #expect(reloaded.settings == EnergySettings(
            smoothing: try #require(TrendSmoothing(alpha: 0.2)),
            rateGoal: E.rate(-0.5),
            adoptionMode: .weeklyAutoAdopt,
            schedule: try FormulaActivationSchedule().activating(E.v2, from: E.day(10), calendar: E.calendar)
        ))
        #expect(reloaded.marks == [E.day(3)])
    }
}
