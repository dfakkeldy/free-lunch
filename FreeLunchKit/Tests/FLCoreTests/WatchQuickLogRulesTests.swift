// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLCore

@Suite struct WatchQuickLogRulesTests {
    @Test func boundaries() {
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(WatchQuickLogRules.coalesces(lastTapAt: t, tapAt: t.addingTimeInterval(600)))
        #expect(!WatchQuickLogRules.coalesces(lastTapAt: t, tapAt: t.addingTimeInterval(601)))
        #expect(!WatchQuickLogRules.coalesces(lastTapAt: t, tapAt: t.addingTimeInterval(-1)))
        #expect(WatchQuickLogRules.canUndo(tapAt: t, now: t.addingTimeInterval(4.999)))
        #expect(!WatchQuickLogRules.canUndo(tapAt: t, now: t.addingTimeInterval(5)))
        #expect(WatchQuickLogRules.portion(lastPortionGrams: 100, steps: -10) == nil)
    }
}
