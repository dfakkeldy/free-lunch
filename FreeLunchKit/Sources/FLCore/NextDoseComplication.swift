// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

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

    public init(nextDose: WatchNextDoseData? = nil, localShotAt: Date? = nil) {
        self.nextDose = nextDose
        self.localShotAt = localShotAt
    }

    public mutating func shotLogged(at: Date, calendar: Calendar, reload: () -> Void) {
        guard var dose = nextDose, let interval = dose.intervalDays,
              let projected = NextDose.projectedDate(takenAt: at, intervalDays: interval, calendar: calendar) else { return }
        dose.nextDoseAt = projected
        nextDose = dose
        localShotAt = at
        reload()
    }

    public mutating func digestApplied(_ digest: WatchDigestData, reload: () -> Void) {
        if let localShotAt, digest.generatedAt < localShotAt { return }
        let oldDate = nextDose?.nextDoseAt
        nextDose = digest.nextDose
        localShotAt = nil
        if oldDate != nextDose?.nextDoseAt { reload() }
    }
}
