// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — the rule for a user-chosen `loggedAt` (spec §1 MealEntry,
// spec §2 "Log": default now, editable for late logging).
//
// Late logging only goes backwards: a plate is logged at "now" or at an
// earlier moment, never in the future. "Now" itself is allowed, so the
// one-tap default and a time picked a moment ago both pass. There is no
// lower bound: a plate can be logged to any earlier day.
import Foundation

public enum LoggedAtRule {
    /// The latest moment a plate may be logged at, given the current time.
    public static func latestAllowed(now: Date) -> Date {
        now
    }

    /// True when `loggedAt` is not after `now`.
    public static func permits(_ loggedAt: Date, now: Date) -> Bool {
        loggedAt <= latestAllowed(now: now)
    }
}
