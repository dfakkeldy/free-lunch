// SPDX-License-Identifier: GPL-3.0-or-later
// Energy settings persistence lane (spec §3 and §6): the persisted home of
// everything EnergyBinding reads that is not a stored meal, weigh-in or
// adopted target. The formula activation schedule, rate goal, trend α,
// adoption mode and the days marked "didn't track" live on the phone store,
// so they survive a relaunch.
//
// - The settings are one row, absent until the first write. A store with no
//   row reads as the spec defaults (`EnergySettings.defaults`), so a fresh
//   install and a store that never touched a setting are the same thing.
// - α is validated here, at the store boundary: the setter takes the raw
//   number and refuses anything outside 0.05–0.25 (or NaN) before any row is
//   touched. Loading validates every field again and refuses a row that
//   fails, so a damaged store never reads as plausible settings.
// - A mark is one row per calendar day. Marking is idempotent.
//
// Nothing here recomputes anything. EnergyRecomputeCoordinator owns when the
// engine runs; this file only holds what it reads.
import FLEnergyCore
import Foundation
import SwiftData

/// Why an energy-settings call was refused.
public enum EnergySettingsError: Error, Equatable, Sendable {
    /// α outside ``TrendSmoothing/allowedAlphaRange`` or not a number.
    case alphaOutOfRange(Double)
    /// The rate goal is not a finite number.
    case invalidRateGoal(Double)
    /// The stored settings row fails validation (α out of range, a
    /// non-finite rate, an unknown adoption mode, or a schedule that does not
    /// decode to a valid one).
    case invalidStoredSettings
    /// The formula activation was refused: it names a day before the latest
    /// activation (activation is forward-only, spec §3).
    case retroactiveActivation(latestEffectiveFrom: Date)
}

/// Settings the energy engine reads, and the days marked "didn't track".
/// Phone store only.
@MainActor
public protocol EnergySettingsStore: AnyObject {
    /// The stored settings, or the spec defaults when none were saved.
    func energySettings() throws -> EnergySettings

    /// Sets α. Throws `alphaOutOfRange` for a value outside 0.05–0.25 and
    /// leaves the store unchanged.
    func setTrendAlpha(_ alpha: Double) throws
    func setRateGoal(kgPerWeek: Double) throws
    func setAdoptionMode(_ mode: AdoptionMode) throws
    /// Replaces the activation schedule.
    func setFormulaActivationSchedule(_ schedule: FormulaActivationSchedule) throws
    /// Appends an activation of `formula` from `day`'s calendar day on
    /// (spec §3: forward-only). Throws `retroactiveActivation` for a day
    /// before the latest activation.
    func activateFormula(_ formula: EnergyFormulaVersion, from day: Date, calendar: Calendar) throws

    /// Marks `day`'s calendar day "didn't track". Marking a marked day
    /// changes nothing.
    func markDidNotTrack(day: Date, calendar: Calendar) throws
    /// Removes the mark; an unmarked day is left as it is.
    func unmarkDidNotTrack(day: Date, calendar: Calendar) throws
    /// The marked days, each the start of its calendar day.
    func didNotTrackDays() throws -> Set<Date>
}

extension SwiftDataStore: EnergySettingsStore {
    public func energySettings() throws -> EnergySettings {
        try requireStoreKind(.phone, operation: "energySettings")
        guard let row = try settingsRow() else { return .defaults }
        return try row.asEnergySettings()
    }

    public func setTrendAlpha(_ alpha: Double) throws {
        try requireStoreKind(.phone, operation: "setTrendAlpha")
        guard TrendSmoothing(alpha: alpha) != nil else {
            throw EnergySettingsError.alphaOutOfRange(alpha)
        }
        try updateSettings { $0.trendAlpha = alpha }
    }

    public func setRateGoal(kgPerWeek: Double) throws {
        try requireStoreKind(.phone, operation: "setRateGoal")
        guard RateGoal(kgPerWeek: kgPerWeek) != nil else {
            throw EnergySettingsError.invalidRateGoal(kgPerWeek)
        }
        try updateSettings { $0.rateGoalKgPerWeek = kgPerWeek }
    }

    public func setAdoptionMode(_ mode: AdoptionMode) throws {
        try requireStoreKind(.phone, operation: "setAdoptionMode")
        try updateSettings { $0.adoptionModeRaw = mode.rawValue }
    }

    public func setFormulaActivationSchedule(_ schedule: FormulaActivationSchedule) throws {
        try requireStoreKind(.phone, operation: "setFormulaActivationSchedule")
        let json = try EnergySettingsCoding.encode(schedule)
        try updateSettings { $0.activationScheduleJSON = json }
    }

    public func activateFormula(_ formula: EnergyFormulaVersion, from day: Date, calendar: Calendar) throws {
        try requireStoreKind(.phone, operation: "activateFormula")
        let current = try energySettings().schedule
        let next: FormulaActivationSchedule
        do {
            next = try current.activating(formula, from: day, calendar: calendar)
        } catch {
            switch error {
            case .retroactive(let latest): throw EnergySettingsError.retroactiveActivation(latestEffectiveFrom: latest)
            }
        }
        let json = try EnergySettingsCoding.encode(next)
        try updateSettings { $0.activationScheduleJSON = json }
    }

    public func markDidNotTrack(day: Date, calendar: Calendar) throws {
        try requireStoreKind(.phone, operation: "markDidNotTrack")
        let start = calendar.startOfDay(for: day)
        guard try markRow(day: start) == nil else { return }
        context.insert(DidNotTrackMark(day: start))
        try commit()
    }

    public func unmarkDidNotTrack(day: Date, calendar: Calendar) throws {
        try requireStoreKind(.phone, operation: "unmarkDidNotTrack")
        guard let row = try markRow(day: calendar.startOfDay(for: day)) else { return }
        context.delete(row)
        try commit()
    }

    public func didNotTrackDays() throws -> Set<Date> {
        try requireStoreKind(.phone, operation: "didNotTrackDays")
        return Set(try context.fetch(FetchDescriptor<DidNotTrackMark>()).map(\.day))
    }

    // MARK: - Helpers

    private func settingsRow() throws -> EnergySettingsRecord? {
        let key = EnergySettingsCoding.singletonKey
        var descriptor = FetchDescriptor<EnergySettingsRecord>(predicate: #Predicate { $0.singletonKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func markRow(day: Date) throws -> DidNotTrackMark? {
        var descriptor = FetchDescriptor<DidNotTrackMark>(predicate: #Predicate { $0.day == day })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Applies `change` to the settings row, creating it from the defaults
    /// first when this is the first write.
    private func updateSettings(_ change: (EnergySettingsRecord) -> Void) throws {
        let row: EnergySettingsRecord
        if let existing = try settingsRow() {
            row = existing
        } else {
            row = EnergySettingsRecord(from: .defaults)
            context.insert(row)
        }
        change(row)
        try commit()
    }
}

// MARK: - Mapping

enum EnergySettingsCoding {
    /// The one settings row's key.
    static let singletonKey = "energy"

    static func encode(_ schedule: FormulaActivationSchedule) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(schedule)
    }

    /// Nil for JSON that is not a valid schedule (decoding checks the
    /// forward-only order).
    static func decodeSchedule(_ data: Data) -> FormulaActivationSchedule? {
        try? JSONDecoder().decode(FormulaActivationSchedule.self, from: data)
    }
}

extension EnergySettingsRecord {
    /// A row holding `settings`' values.
    convenience init(from settings: EnergySettings) {
        self.init(
            singletonKey: EnergySettingsCoding.singletonKey,
            trendAlpha: settings.smoothing.alpha,
            rateGoalKgPerWeek: settings.rateGoal.kgPerWeek,
            adoptionModeRaw: settings.adoptionMode.rawValue,
            activationScheduleJSON: nil
        )
    }

    func asEnergySettings() throws -> EnergySettings {
        guard let smoothing = TrendSmoothing(alpha: trendAlpha),
              let rateGoal = RateGoal(kgPerWeek: rateGoalKgPerWeek),
              let mode = AdoptionMode(rawValue: adoptionModeRaw)
        else {
            throw EnergySettingsError.invalidStoredSettings
        }
        let schedule: FormulaActivationSchedule
        if let activationScheduleJSON {
            guard let decoded = EnergySettingsCoding.decodeSchedule(activationScheduleJSON) else {
                throw EnergySettingsError.invalidStoredSettings
            }
            schedule = decoded
        } else {
            schedule = FormulaActivationSchedule()
        }
        return EnergySettings(smoothing: smoothing, rateGoal: rateGoal, adoptionMode: mode, schedule: schedule)
    }
}
