// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation

/// A neutral indicator; the app supplies the intake interpretation.
public enum TimelineGlyph: Sendable, Hashable {
    case complete, markedNotTracked, empty

    public var symbol: String {
        switch self {
        case .complete: "checkmark.circle"
        case .markedNotTracked: "minus.circle"
        case .empty: "circle"
        }
    }
    public var accessibilityLabel: String {
        switch self {
        case .complete: "Intake recorded"
        case .markedNotTracked: "Didn't track"
        case .empty: "No intake recorded"
        }
    }
}

public enum TimelineItem: Sendable, Hashable, Identifiable {
    case meal(MealEntryData), shot(ShotEventData), weight(CorrectedWeightSample)
    case sideEffect(SideEffectEntryData), journal(JournalEntryData)
    case plannedShot(PlannedShotData), plannedMeal(PlannedMealData)

    public var id: String {
        switch self {
        case .meal(let x): "meal-\(x.id)"
        case .shot(let x): "shot-\(x.id)"
        case .weight(let x): "weight-\(x.id)"
        case .sideEffect(let x): "effect-\(x.id)"
        case .journal(let x): "journal-\(x.id)"
        case .plannedShot(let x): "planned-shot-\(x.id)"
        case .plannedMeal(let x): "planned-meal-\(x.id)"
        }
    }
    public var date: Date {
        switch self {
        case .meal(let x): x.loggedAt ?? x.createdAt
        case .shot(let x): x.takenAt
        case .weight(let x): x.measuredAt
        case .sideEffect(let x): x.occurredAt
        case .journal(let x): x.at
        case .plannedShot(let x): x.plannedAt
        case .plannedMeal(let x): x.plannedAt
        }
    }
}

public struct TimelineDay: Sendable, Hashable, Identifiable {
    public let day: Date
    public let items: [TimelineItem]
    public var id: Date { day }
}

public struct TimelineFeed: Sendable {
    public let upcoming: [TimelineItem]
    public let today: TimelineDay
    public let past: [TimelineDay]

    /// Includes thirty recent empty days, and older days that have records or marks.
    public static func build(now: Date, calendar: Calendar, meals: [MealEntryData],
        shots: [ShotEventData], weights: [CorrectedWeightSample], effects: [SideEffectEntryData],
        journal: [JournalEntryData], plannedShots: [PlannedShotData], plannedMeals: [PlannedMealData],
        markedDays: Set<Date> = []) -> TimelineFeed {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: today)!
        let upcoming = (plannedShots.filter { $0.status == .pending }.map(TimelineItem.plannedShot)
            + plannedMeals.filter { $0.status == .pending }.map(TimelineItem.plannedMeal))
            .filter { $0.date >= now && $0.date < end }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        let records = meals.map(TimelineItem.meal) + shots.map(TimelineItem.shot)
            + weights.map(TimelineItem.weight) + effects.map(TimelineItem.sideEffect)
            + journal.map(TimelineItem.journal)
        let grouped = Dictionary(grouping: records.filter { $0.date < end }) { item in
            // Drafts remain visible in Today until logged.
            if case .meal(let meal) = item, meal.state == .draft { return today }
            return calendar.startOfDay(for: item.date)
        }
        func items(_ day: Date) -> [TimelineItem] {
            (grouped[day] ?? []).sorted { ($0.date, $0.id) > ($1.date, $1.id) }
        }
        var days = Set(grouped.keys.filter { $0 < today })
        days.formUnion(markedDays.map { calendar.startOfDay(for: $0) }.filter { $0 < today })
        for offset in 1...30 {
            if let day = calendar.date(byAdding: .day, value: -offset, to: today) { days.insert(day) }
        }
        return TimelineFeed(upcoming: upcoming, today: TimelineDay(day: today, items: items(today)),
            past: days.sorted(by: >).map { TimelineDay(day: $0, items: items($0)) })
    }
}
