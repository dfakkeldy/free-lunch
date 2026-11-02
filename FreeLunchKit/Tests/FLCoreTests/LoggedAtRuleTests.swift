// SPDX-License-Identifier: GPL-3.0-or-later
// The late-logging rule (spec §2 "Log"): a plate is logged now or earlier,
// never in the future.
import FLCore
import Foundation
import Testing

@Suite("loggedAt rule: never in the future")
struct LoggedAtRuleTests {
    /// 2026-01-05 14:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_767_621_600)

    @Test("now itself is allowed, so the one-tap default always passes")
    func nowAllowed() {
        #expect(LoggedAtRule.permits(now, now: now))
        #expect(LoggedAtRule.latestAllowed(now: now) == now)
    }

    @Test("any earlier moment is allowed, however far back")
    func earlierAllowed() {
        #expect(LoggedAtRule.permits(now.addingTimeInterval(-1), now: now))
        #expect(LoggedAtRule.permits(now.addingTimeInterval(-86_400), now: now))
        #expect(LoggedAtRule.permits(Date(timeIntervalSince1970: 0), now: now))
    }

    @Test("a moment after now is refused, even one second")
    func futureRefused() {
        #expect(!LoggedAtRule.permits(now.addingTimeInterval(1), now: now))
        #expect(!LoggedAtRule.permits(now.addingTimeInterval(86_400), now: now))
    }
}
