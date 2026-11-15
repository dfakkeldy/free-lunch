// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum NextDoseComplicationConfiguration {
    public static let appGroup = "group.com.freelunch.nutrition"
    public static let stateKey = "nextDoseComplicationState"
    public static let kind = "NextDose"
}

public enum NextDoseComplicationLabel {
    public static func overdue(days: Int) -> String {
        if days == 0 { return "Due today" }
        if days == 1 { return "Due 1 day ago" }
        return "Due \(days) days ago"
    }
}

public struct NextDoseTimelineEntry: Sendable, Hashable {
    public let date: Date
    public let status: NextDoseStatus?
}

public enum NextDoseTimeline {
    /// A finite horizon; WidgetKit requests another timeline at its end.
    public static func entries(dueAt: Date?, now: Date, calendar: Calendar, overdueDays: Int = 30) -> [NextDoseTimelineEntry] {
        guard let dueAt else { return [.init(date: now, status: nil)] }
        var dates = [now]
        let day = calendar.startOfDay(for: dueAt)
        for date in [day, dueAt, dueAt.addingTimeInterval(1)] where date > now { dates.append(date) }
        var midnight = calendar.startOfDay(for: max(now, dueAt))
        for _ in 0..<max(1, overdueDays) {
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
            midnight = next
            dates.append(next)
        }
        return Array(Set(dates)).sorted().map { .init(date: $0, status: NextDose.status(dueAt: dueAt, now: $0, calendar: calendar)) }
    }
}

/// The caller persists this value alongside the projection across launches.
public struct NextDoseComplicationState: Codable, Sendable {
    public private(set) var nextDose: WatchNextDoseData?
    public private(set) var localShotAt: Date?
    public private(set) var previousDueAt: Date?

    public init(nextDose: WatchNextDoseData? = nil, localShotAt: Date? = nil) {
        self.nextDose = nextDose
        self.localShotAt = localShotAt
        self.previousDueAt = nil
    }

    public mutating func shotLogged(at: Date, calendar: Calendar, reload: () -> Void) {
        previousDueAt = nextDose?.nextDoseAt
        if var dose = nextDose, let interval = dose.intervalDays,
           let projected = NextDose.projectedDate(takenAt: at, intervalDays: interval, calendar: calendar) {
            dose.nextDoseAt = projected
            nextDose = dose
        } else {
            nextDose = nil
        }
        localShotAt = at
        reload()
    }

    public mutating func digestApplied(_ digest: WatchDigestData, reload: () -> Void) {
        if let localShotAt {
            guard digest.generatedAt >= localShotAt, let incoming = digest.nextDose?.nextDoseAt else { return }
            if incoming != nextDose?.nextDoseAt, let previousDueAt, incoming <= previousDueAt { return }
        }
        let oldDate = nextDose?.nextDoseAt
        nextDose = digest.nextDose
        localShotAt = nil
        previousDueAt = nil
        if oldDate != nextDose?.nextDoseAt { reload() }
    }
}
