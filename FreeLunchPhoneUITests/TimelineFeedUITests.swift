// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

final class TimelineFeedUITests: XCTestCase {
    @MainActor
    func testFeedOrderAndReturnToTodayAfterLog() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launchArguments += ["-FLUITestInMemoryStore", "-FLUITestSeedTimeline"]
        app.launch()
        let upcoming = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Synthetic upcoming 1'")).firstMatch
        let draft = app.buttons["timeline.draftRow"].firstMatch
        XCTAssertTrue(upcoming.waitForExistence(timeout: 15))
        for _ in 0..<5 where !draft.isHittable { app.swipeUp() }
        XCTAssertTrue(draft.isHittable)
        let today = app.staticTexts["timeline.today.header"]
        XCTAssertTrue(today.exists)
        let one = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Synthetic day 1'")).firstMatch
        for _ in 0..<4 where !one.isHittable { app.swipeUp() }
        XCTAssertTrue(one.isHittable)
        let two = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Synthetic day 2'")).firstMatch
        let three = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Synthetic day 3'")).firstMatch
        XCTAssertTrue(two.exists)
        XCTAssertTrue(three.exists)
        XCTAssertLessThan(one.frame.minY, two.frame.minY)
        XCTAssertLessThan(two.frame.minY, three.frame.minY)
        for _ in 0..<4 where today.isHittable { app.swipeUp() }
        XCTAssertFalse(today.isHittable)
        app.buttons["timeline.log"].tap()
        XCTAssertTrue(app.buttons["plate.log"].waitForExistence(timeout: 10))
        app.buttons["plate.log"].tap()
        XCTAssertTrue(app.navigationBars["Logged"].waitForExistence(timeout: 10))
        let bar = app.navigationBars["Logged"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        XCTAssertTrue(today.isHittable)
    }

    @MainActor
    func testMarkAndUnmarkToday() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launchArguments += ["-FLUITestInMemoryStore", "-FLUITestSeedDraft"]
        app.launch()
        let menu = app.buttons["Day options"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["Didn't track today"].tap()
        menu.tap()
        XCTAssertTrue(app.buttons["Undo didn't track"].waitForExistence(timeout: 10))
        app.buttons["Undo didn't track"].tap()
        menu.tap()
        XCTAssertTrue(app.buttons["Didn't track today"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPastDayGlyphsAndMark() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launchArguments += ["-FLUITestInMemoryStore", "-FLUITestSeedLoggedYesterday"]
        app.launch()
        XCTAssertTrue(app.images["Intake recorded"].waitForExistence(timeout: 15))
        let menus = app.buttons.matching(identifier: "Day options")
        XCTAssertGreaterThanOrEqual(menus.count, 2)
        menus.element(boundBy: 1).tap()
        app.buttons["Didn't track this day"].tap()
        XCTAssertTrue(app.images["Didn't track"].waitForExistence(timeout: 10))
        menus.element(boundBy: 1).tap()
        app.buttons["Undo didn't track"].tap()
        XCTAssertTrue(app.images["Intake recorded"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["No intake recorded"].exists)
    }

    @MainActor
    func testReopenYesterdayPlate() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launchArguments += ["-FLUITestInMemoryStore", "-FLUITestSeedLoggedYesterday"]
        app.launch()
        let row = app.buttons["timeline.loggedRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.navigationBars["Logged plate"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Synthetic soup"].exists)
    }
}
