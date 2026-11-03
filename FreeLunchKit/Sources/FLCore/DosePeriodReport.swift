// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — per-period report rows for Insights (spec §5 "Dose-strength
// periods" and "Hunger & side effects in the lane").
//
// A report is a derived `DosePeriod` plus counts of what happened inside it.
// It is derived at query time and never stored. Counts, not conclusions:
// nothing here relates hunger or side effects to the dose, the trend or each
// other.
//
// Boundaries (the convention `DosePeriod.contains` already uses):
// - A record belongs to the period whose time span contains its instant:
//   [start, end) for a closed period, [start, end] for the open last period.
//   Instants, not calendar days: on the day a new strength starts, a record
//   stamped before the shot is in the old period and one at or after it is
//   in the new period. A record stamped exactly at the shot belongs to the
//   new period; exactly at `asOf`, to the open period.
// - Records before the first shot or after the open period's end are in no
//   period. That end is `asOf`, or the last shot when it is stamped later
//   (a future-dated shot): a record between `asOf` and that shot is counted
//   in the open period, so the counts always cover the period's own span.
//
// Hunger (spec §2 "Hunger", §5):
// - The unit is a logged meal (`state == .logged`, placed by `loggedAt`).
//   Drafts have no logged time and are never counted. That includes a draft
//   a watch hunger quick-log created: its rating is not in any period until
//   the draft is logged on the phone.
// - A logged meal imported from Apple Health (`.healthKitImport`) carries no
//   rating, so it counts as unknown like any other unrated meal.
// - A meal with no hunger is unknown and is counted as unknown, never
//   imputed: it adds nothing to the mean.
// - A stored value outside `DomainScale.hunger` cannot be a rating; the
//   store rejects it, so seeing one is a data fault. It is treated as
//   unknown and never enters the mean.
// - The mean is nil when no meal in the period has a rating (never 0).
//
// Side effects (spec §5): counted by `SideEffectType` exactly as stored,
// placed by `occurredAt`. `.other` entries are keyed by their text with no
// normalisation, so "Headache" and "headache" are different keys. A type
// with no entries in the period has no key; its count is 0.
//
// Trend change, duration, weekly rate, injection count and coverage come
// straight from `DosePeriod`; see its header for their definitions. The
// trend is a held value (spec §3: no new information between weigh-ins), so
// a boundary with no weigh-in that day carries the last trend forward; the
// change is nil only while no trend is defined at a boundary.
import Foundation

/// Hunger ratings (1 to 5) of the logged meals in one period.
public struct HungerSummary: Sendable, Hashable {
    /// Meals with a valid rating, by level. Every level 1 to 5 has a key.
    public let countsByLevel: [Int: Int]
    /// Logged meals with no usable rating. Never imputed.
    public let unknownCount: Int

    public var ratedCount: Int { countsByLevel.values.reduce(0, +) }

    /// Logged meals in the period, rated or not.
    public var mealCount: Int { ratedCount + unknownCount }

    /// Mean of the ratings only, or nil when there are none.
    public var mean: Double? {
        let rated = ratedCount
        guard rated > 0 else { return nil }
        let sum = countsByLevel.reduce(0) { $0 + $1.key * $1.value }
        return Double(sum) / Double(rated)
    }

    public init(ratings: [Int?]) {
        var counts = Dictionary(uniqueKeysWithValues: DomainScale.hunger.map { ($0, 0) })
        var unknown = 0
        for rating in ratings {
            if let rating, DomainScale.hunger.contains(rating) {
                counts[rating, default: 0] += 1
            } else {
                unknown += 1
            }
        }
        countsByLevel = counts
        unknownCount = unknown
    }
}

/// Side-effect counts by type in one period.
public struct SideEffectSummary: Sendable, Hashable {
    public let countsByType: [SideEffectType: Int]

    public var totalCount: Int { countsByType.values.reduce(0, +) }

    public init(types: [SideEffectType]) {
        countsByType = types.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}

/// One dose period with its counts.
public struct DosePeriodReport: Sendable, Hashable {
    public let period: DosePeriod
    public let hunger: HungerSummary
    public let sideEffects: SideEffectSummary

    public var injectionCount: Int { period.injectionCount }
    public var durationDays: Double { period.durationDays }
    public var coverage: Double? { period.coverage }
    public var totalChangeKg: Double? { period.totalChangeKg }
    public var weeklyRateKg: Double? { period.weeklyRateKg }
}

public enum DosePeriodReports {
    /// Derives the periods and fills each with its hunger and side-effect
    /// counts.
    ///
    /// - Parameters:
    ///   - meals: any meals; drafts and meals without `loggedAt` are skipped.
    ///   - sideEffects: any side-effect entries.
    ///   - trendKg: trend weight at a date, or nil where none is defined.
    ///     FLCore has no trend model; FLPersistence binds the §3 series.
    public static func reports(
        shots: [ShotEventData],
        profiles: [MedicationProfileData],
        meals: [MealEntryData],
        sideEffects: [SideEffectEntryData],
        asOf: Date,
        trendKg: (Date) -> Double? = { _ in nil }
    ) -> [DosePeriodReport] {
        let periods = DosePeriodDerivation.periods(
            shots: shots,
            profiles: profiles,
            asOf: asOf,
            trendKg: trendKg
        )
        let logged: [(at: Date, hunger: Int?)] = meals.compactMap { meal in
            guard meal.state == .logged, let at = meal.loggedAt else { return nil }
            return (at, meal.hunger)
        }
        return periods.map { period in
            DosePeriodReport(
                period: period,
                hunger: HungerSummary(
                    ratings: logged.filter { period.contains($0.at) }.map(\.hunger)
                ),
                sideEffects: SideEffectSummary(
                    types: sideEffects.filter { period.contains($0.occurredAt) }.map(\.type)
                )
            )
        }
    }
}
