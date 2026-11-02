// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 acceptance #7 on the real app: after the explicit Log action the
// post-log sheet shows remaining-vs-target above the daily totals, and one
// swipe dismisses it straight back to the timeline. A screenshot of the
// sheet is attached for the acceptance digest.

import XCTest

final class PostLogSurfaceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testPostLogSheetShowsRemainingAboveTotalsAndDismissesToTimelineInOneGesture() {
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launchArguments += ["-FLUITestInMemoryStore", "-FLUITestSeedDraft"]
        app.launch()

        // The seeded draft is on the timeline; open it.
        let draft = app.buttons["timeline.draftRow"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        draft.tap()

        // The plate shows its running total and remaining, then Log.
        let total = app.staticTexts["plate.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        XCTAssertEqual(total.label, "250 kcal")
        XCTAssertEqual(app.staticTexts["plate.remaining"].label, "No target adopted")

        let log = app.buttons["plate.log"]
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        log.tap()

        // Remaining sits above the daily totals.
        let remaining = app.staticTexts["postLog.section.remaining"]
        let totals = app.staticTexts["postLog.section.dailyTotals"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 10))
        XCTAssertTrue(totals.waitForExistence(timeout: 5))
        XCTAssertLessThan(remaining.frame.minY, totals.frame.minY)
        XCTAssertTrue(app.staticTexts["No target adopted"].exists)
        XCTAssertTrue(app.staticTexts["250 kcal"].exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "post-log-sheet"
        shot.lifetime = .keepAlways
        add(shot)

        // One gesture: swipe the sheet down by its bar.
        let sheetBar = app.navigationBars["Logged"]
        XCTAssertTrue(sheetBar.exists)
        sheetBar.swipeDown(velocity: .fast)
        XCTAssertTrue(remaining.waitForNonExistence(timeout: 10))

        // Back on the timeline, not the plate: the Log action is there, the
        // plate's Log button is gone, and the plate is now logged.
        XCTAssertTrue(app.buttons["timeline.log"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["plate.log"].exists)
        XCTAssertTrue(app.buttons["timeline.loggedRow"].firstMatch.waitForExistence(timeout: 5))
    }
}
