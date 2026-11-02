// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 "Log" and acceptance #8 on the real app: a plate logged to
// yesterday lands in yesterday, and the post-log sheet speaks of yesterday
// ("Remaining yesterday", yesterday's totals); a logged plate's time can be
// changed afterwards and the plate leaves today. The seeded draft is one
// synthetic 250 kcal item and nothing else is logged, so yesterday's total
// after logging it there is exactly 250 kcal.
//
// The move test also seeds a synthetic plate logged yesterday (400 kcal,
// P 20 g, C 50 g, F 12 g). Moving the 250 kcal plate (P 8, C 30, F 10)
// there from today leaves today at 0 and yesterday at 400 + 250 = 650,
// P 28, C 80, F 22: worked by hand, and read back from the app model's
// move readout on the plate.

import XCTest

final class LateLoggingUITests: XCTestCase {
    @MainActor
    func testLogPlateToYesterdayShowsYesterdaysSheet() {
        continueAfterFailure = false
        let app = launchWithSeededDraft()
        openSeededDraft(in: app)

        // The one-tap default is still there; the earlier-time control sits
        // beside it with a spoken label.
        XCTAssertTrue(app.buttons["plate.log"].exists)
        let earlier = app.buttons["plate.logEarlier"]
        XCTAssertTrue(earlier.exists)
        XCTAssertEqual(earlier.label, "Log at an earlier time")
        earlier.tap()

        pickSameTimeYesterday(in: app)
        XCTAssertEqual(app.buttons["loggedAt.confirm"].label, "Log plate at this time")
        app.buttons["loggedAt.confirm"].tap()

        // The post-log sheet follows the logged day.
        let remaining = app.staticTexts["postLog.section.remaining"]
        let totals = app.staticTexts["postLog.section.dailyTotals"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 10))
        XCTAssertTrue(totals.waitForExistence(timeout: 5))
        XCTAssertEqual(remaining.label, "Remaining yesterday")
        XCTAssertEqual(totals.label, "Yesterday's totals")
        XCTAssertLessThan(remaining.frame.minY, totals.frame.minY)
        XCTAssertTrue(app.staticTexts["No target adopted"].exists)
        XCTAssertTrue(app.staticTexts["250 kcal"].exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "post-log-sheet-yesterday"
        shot.lifetime = .keepAlways
        add(shot)

        // Done: back on the timeline, where today has nothing logged.
        app.buttons["postLog.done"].tap()
        XCTAssertTrue(remaining.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["phone.emptyState.heading"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["timeline.loggedRow"].exists)
    }

    @MainActor
    func testLoggedPlateTimeCanBeMovedToYesterday() {
        continueAfterFailure = false
        let app = launchWithSeededDraft(extraArguments: ["-FLUITestSeedLoggedYesterday"])
        openSeededDraft(in: app)

        // Log at now, the unchanged default: the sheet speaks of today, and
        // yesterday's seeded plate is not in today's total.
        app.buttons["plate.log"].tap()
        let remaining = app.staticTexts["postLog.section.remaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 10))
        XCTAssertEqual(remaining.label, "Remaining today")
        XCTAssertEqual(app.staticTexts["postLog.section.dailyTotals"].label, "Today's totals")
        XCTAssertTrue(app.staticTexts["250 kcal"].exists)
        app.buttons["postLog.done"].tap()
        XCTAssertTrue(remaining.waitForNonExistence(timeout: 10))

        // Reopen the logged plate: its time reads today.
        let loggedRow = app.buttons["timeline.loggedRow"].firstMatch
        XCTAssertTrue(loggedRow.waitForExistence(timeout: 5))
        loggedRow.tap()
        let loggedAt = app.buttons["plate.loggedAt"]
        XCTAssertTrue(loggedAt.waitForExistence(timeout: 10))
        XCTAssertEqual(loggedAt.label, "Logged time")
        XCTAssertTrue((loggedAt.value as? String)?.hasPrefix("Today, ") == true)

        // Move it to the same time yesterday.
        loggedAt.tap()
        pickSameTimeYesterday(in: app)
        XCTAssertEqual(app.buttons["loggedAt.confirm"].label, "Save the new time")
        app.buttons["loggedAt.confirm"].tap()
        XCTAssertTrue(app.buttons["loggedAt.confirm"].waitForNonExistence(timeout: 10))
        let movedValue = NSPredicate(format: "value BEGINSWITH 'Yesterday, '")
        expectation(for: movedValue, evaluatedWith: loggedAt)
        waitForExpectations(timeout: 10)

        // Both days' totals after the move, exactly.
        let left = app.staticTexts["plate.moved.previous"]
        let joined = app.staticTexts["plate.moved.current"]
        XCTAssertTrue(joined.waitForExistence(timeout: 10))
        XCTAssertEqual(left.label, "Today: 0 kcal · P 0 g · C 0 g · F 0 g")
        XCTAssertEqual(joined.label, "Yesterday: 650 kcal · P 28 g · C 80 g · F 22 g")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "logged-plate-moved-to-yesterday"
        shot.lifetime = .keepAlways
        add(shot)

        // Today no longer holds it.
        app.navigationBars["Logged plate"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["phone.emptyState.heading"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["timeline.loggedRow"].exists)
    }

    // MARK: Helpers

    @MainActor
    private func launchWithSeededDraft(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launchArguments += ["-FLUITestInMemoryStore", "-FLUITestSeedDraft"] + extraArguments
        app.launch()
        return app
    }

    @MainActor
    private func openSeededDraft(in app: XCUIApplication) {
        let draft = app.buttons["timeline.draftRow"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        draft.tap()
        let total = app.staticTexts["plate.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        XCTAssertEqual(total.label, "250 kcal")
    }

    /// In the time sheet: one tap on "Same time yesterday", then the footer
    /// confirms the day before anything is committed.
    @MainActor
    private func pickSameTimeYesterday(in app: XCUIApplication) {
        let yesterday = app.buttons["loggedAt.yesterday"]
        XCTAssertTrue(yesterday.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["loggedAt.picker"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts["loggedAt.day"].label, "Counts toward today")
        yesterday.tap()
        XCTAssertEqual(app.staticTexts["loggedAt.day"].label, "Counts toward yesterday")
    }
}
