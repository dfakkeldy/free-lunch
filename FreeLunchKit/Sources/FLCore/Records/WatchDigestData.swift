// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — the phone → watch digest (spec §9 sync, §1 store shape).
//
// One value, published latest-wins by the phone. The watch stores the
// ranked recent foods as its RecentFoodSnapshot rows; the next-dose and
// today-remaining glance values stay in memory on the watch, because the
// transport retains the latest digest across a relaunch (WatchConnectivity's
// application context), so they need no stored home there.
//
// Plain Codable values only: these cross the device boundary, so no FLPlate
// or FLEnergyCore type appears here. Units are canonical (kcal, grams,
// milligrams).
import Foundation

public struct WatchDigestData: Sendable, Hashable, Codable {
    /// Spec §1 store shape: the watch keeps about 200 recent foods.
    public static let recentFoodCap = 200

    /// When the phone built this digest. The watch never applies a digest
    /// older than the one it already shows.
    public var generatedAt: Date
    /// Best first, as the phone ranked them; at most `recentFoodCap`.
    public var recentFoods: [RecentFoodSnapshotData]
    /// nil when there is nothing to project (no shot, or the lane is off).
    public var nextDose: WatchNextDoseData?
    /// nil when the phone sent no day summary.
    public var todayRemaining: WatchTodayRemainingData?

    public init(
        generatedAt: Date,
        recentFoods: [RecentFoodSnapshotData],
        nextDose: WatchNextDoseData? = nil,
        todayRemaining: WatchTodayRemainingData? = nil
    ) {
        self.generatedAt = generatedAt
        self.recentFoods = recentFoods
        self.nextDose = nextDose
        self.todayRemaining = todayRemaining
    }
}

/// The next-dose card and complication (spec §9, projection rule §5). The
/// phone projects `nextDoseAt`; the watch only renders it and offers
/// "Taken now" with the medication and dose carried here.
public struct WatchNextDoseData: Sendable, Hashable, Codable {
    public var medicationID: UUID
    public var medicationName: String
    /// Canonical milligrams of the most recent shot, the "Taken now" default.
    public var doseMg: Double
    public var nextDoseAt: Date

    public init(medicationID: UUID, medicationName: String, doseMg: Double, nextDoseAt: Date) {
        self.medicationID = medicationID
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.nextDoseAt = nextDoseAt
    }
}

/// kcal and the three macros, canonical units.
public struct WatchMacroValues: Sendable, Hashable, Codable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double

    public init(kcal: Double, proteinG: Double, carbsG: Double, fatG: Double) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }
}

/// Today's remaining for the watch root (spec §9; semantics §2 "Post-log
/// surface"): the adopted target and what was logged, per field.
public struct WatchTodayRemainingData: Sendable, Hashable, Codable {
    /// Start of the calendar day these numbers describe. The watch shows
    /// them only on that day, so yesterday's summary never reads as today's.
    public var day: Date
    public var consumed: WatchMacroValues
    /// The adopted target (fat as its floor), or nil for "no target
    /// adopted". Never imputed.
    public var target: WatchMacroValues?

    public init(day: Date, consumed: WatchMacroValues, target: WatchMacroValues?) {
        self.day = day
        self.consumed = consumed
        self.target = target
    }

    /// `target − consumed` per field; negative means over (for fat, that
    /// the floor is met). nil when no target is adopted.
    public var remaining: WatchMacroValues? {
        guard let target else { return nil }
        return WatchMacroValues(
            kcal: target.kcal - consumed.kcal,
            proteinG: target.proteinG - consumed.proteinG,
            carbsG: target.carbsG - consumed.carbsG,
            fatG: target.fatG - consumed.fatG
        )
    }
}
