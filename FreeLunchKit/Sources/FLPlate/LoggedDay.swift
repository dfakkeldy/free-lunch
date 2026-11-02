// SPDX-License-Identifier: GPL-3.0-or-later
// Late logging on the phone (spec §2 "Log": `loggedAt` defaults to now and
// is editable; acceptance #8). `LoggedDay` names the calendar day a plate
// was logged into, relative to now, so the post-log sheet can say
// "Remaining yesterday" instead of "Remaining today". `LateLogTime` holds
// the quick choices the Log-earlier sheet offers.
//
// Like the rest of FLPlate's presentation text this is locale-independent
// (fixed English month abbreviations), so tests can predict every
// character. The calendar decides the day boundaries and time zone.
import FLCore
import Foundation

public enum LoggedDay: Sendable, Hashable {
    case today
    case yesterday
    /// Any other day, with its short date ("Jan 3", or "Dec 31, 2025"
    /// outside the current year).
    case other(String)

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public init(loggedAt: Date, now: Date, calendar: Calendar) {
        if calendar.isDate(loggedAt, inSameDayAs: now) {
            self = .today
            return
        }
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(loggedAt, inSameDayAs: dayBefore) {
            self = .yesterday
            return
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: loggedAt)
        let month = parts.month.flatMap { (1...12).contains($0) ? Self.months[$0 - 1] : nil } ?? "?"
        let day = parts.day.map(String.init) ?? "?"
        let short = "\(month) \(day)"
        if let year = parts.year, year != calendar.component(.year, from: now) {
            self = .other("\(short), \(year)")
        } else {
            self = .other(short)
        }
    }

    /// Standalone name: "Today", "Yesterday", "Jan 3".
    public var name: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case let .other(date): date
        }
    }

    /// The post-log sheet's first heading.
    public var remainingTitle: String {
        switch self {
        case .today: "Remaining today"
        case .yesterday: "Remaining yesterday"
        case let .other(date): "Remaining on \(date)"
        }
    }

    /// The post-log sheet's totals heading.
    public var totalsTitle: String {
        switch self {
        case .today: "Today's totals"
        case .yesterday: "Yesterday's totals"
        case let .other(date): "Totals for \(date)"
        }
    }

    /// Which day's totals a chosen time counts toward, shown under the
    /// time picker before committing.
    public var countsTowardText: String {
        switch self {
        case .today: "Counts toward today"
        case .yesterday: "Counts toward yesterday"
        case let .other(date): "Counts toward \(date)"
        }
    }
}

public enum LateLogTime {
    /// The same clock time one calendar day earlier (23 or 25 hours across
    /// a daylight-saving change). Always in the past, and always in the
    /// previous calendar day, so it is a safe one-tap "yesterday".
    public static func sameTimeYesterday(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
    }

    /// The picker's starting value: the current `loggedAt` when editing a
    /// logged plate, otherwise now; never later than now.
    public static func initialSelection(current: Date?, now: Date) -> Date {
        guard let current, LoggedAtRule.permits(current, now: now) else { return now }
        return current
    }
}
