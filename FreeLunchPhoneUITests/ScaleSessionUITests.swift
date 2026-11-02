// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 "Weighing flows" on the real app: one cumulative scale session of
// two items, then a misread below the running total that is refused, asks
// for re-entry and stores nothing (acceptance #3). Synthetic foods only:
// oats at 400 kcal and yogurt at 50 kcal per 100 g.

import XCTest

final class ScaleSessionUITests: XCTestCase {
    @MainActor
    func testCumulativeSessionAddsTwoScaleItemsAndRefusesAFallingReading() {
        continueAfterFailure = false
        let app = launchWithSeededFoods()

        startCumulativeSession(in: app)
        XCTAssertEqual(app.staticTexts["plate.scale.status"].firstMatch.label, "Tare the empty bowl once, then add food")

        // Item 1: the scale reads 80 g → 80 g of oats = 320 kcal.
        pick("Synthetic oats", in: app)
        enterReading("80", in: app)
        XCTAssertEqual(app.staticTexts["scale.preview"].label, "Adds 80 g")
        app.buttons["scale.add"].tap()
        XCTAssertTrue(app.textFields["scale.reading"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["plate.total"].label, "320 kcal")
        XCTAssertEqual(app.staticTexts["plate.scale.status"].firstMatch.label, "Scale showed 80 g")

        // Item 2: no tare, the scale now reads 280 g → 280 − 80 = 200 g of
        // yogurt = 100 kcal; the plate is 420 kcal.
        pick("Synthetic yogurt", in: app)
        enterReading("280", in: app)
        XCTAssertEqual(app.staticTexts["scale.preview"].label, "Adds 200 g")
        app.buttons["scale.add"].tap()
        XCTAssertTrue(app.textFields["scale.reading"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["plate.total"].label, "420 kcal")
        XCTAssertEqual(app.staticTexts["plate.scale.status"].firstMatch.label, "Scale showed 280 g")

        // Both items carry the scale glyph, with their per-item grams.
        let scaleRows = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Scale' AND label CONTAINS 'kcal'"))
        XCTAssertEqual(scaleRows.count, 2)
        XCTAssertTrue(rowExists(name: "Synthetic oats", grams: "80 g", kcal: "320 kcal", in: app))
        XCTAssertTrue(rowExists(name: "Synthetic yogurt", grams: "200 g", kcal: "100 kcal", in: app))

        // A misread: 250 g is below the 280 g total. Refused, re-entry asked,
        // nothing stored, the running total unchanged.
        pick("Synthetic oats", in: app)
        enterReading("250", in: app)
        app.buttons["scale.add"].tap()
        let prompt = app.staticTexts["scale.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertEqual(
            prompt.label,
            "250 g is less than the last total of 280 g. Check the scale and enter the new total."
        )
        // The field is cleared for re-entry, so there is nothing to add yet.
        XCTAssertFalse(app.staticTexts["scale.preview"].exists)
        XCTAssertFalse(app.buttons["scale.add"].isEnabled)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "scale-session-reentry"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["scale.cancel"].tap()
        XCTAssertTrue(app.textFields["scale.reading"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["plate.total"].label, "420 kcal")
        XCTAssertEqual(app.staticTexts["plate.scale.status"].firstMatch.label, "Scale showed 280 g")
        XCTAssertEqual(scaleRows.count, 2)
    }

    /// At the largest accessibility text size the reading field keeps the
    /// row's width and stays on screen.
    @MainActor
    func testReadingFieldFitsAtLargestTextSize() {
        continueAfterFailure = false
        let app = launchWithSeededFoods(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])

        startCumulativeSession(in: app)
        pick("Synthetic oats", in: app)

        let field = app.textFields["scale.reading"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(field.isHittable)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(field.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(field.frame.maxX, window.maxX)
        XCTAssertGreaterThan(field.frame.width, window.width / 2)

        field.tap()
        field.typeText("1234.5")
        XCTAssertEqual(field.value as? String, "1234.5")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "scale-reading-ax-xxxl"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: Steps

    @MainActor
    private func launchWithSeededFoods(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launchArguments += ["-FLUITestInMemoryStore", "-FLUITestSeedFoods"] + extraArguments
        app.launch()

        // A fresh plate from the timeline's Log action.
        let log = app.buttons["timeline.log"]
        XCTAssertTrue(log.waitForExistence(timeout: 15))
        log.tap()
        XCTAssertTrue(app.staticTexts["plate.total"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func startCumulativeSession(in app: XCUIApplication) {
        let start = app.buttons["plate.scale.startCumulative"]
        reveal(start, in: app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(start.label, "Start cumulative scale session")
        start.tap()
        XCTAssertTrue(app.buttons["plate.scale.end"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func pick(_ food: String, in app: XCUIApplication) {
        let search = app.textFields["plate.search"]
        reveal(search, in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(food)
        let row = app.buttons["plate.typeahead.food"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains(food))
        row.tap()
    }

    /// Scrolls the plate list up until `element` can be tapped. The drag
    /// starts low on the screen: the plate header pinned at the top is not
    /// part of the list.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        guard list.waitForExistence(timeout: 10) else { return }
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < 8 {
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            from.press(forDuration: 0.05, thenDragTo: to)
            attempts += 1
        }
    }

    @MainActor
    private func enterReading(_ reading: String, in app: XCUIApplication) {
        let field = app.textFields["scale.reading"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(reading)
    }

    @MainActor
    private func rowExists(name: String, grams: String, kcal: String, in app: XCUIApplication) -> Bool {
        let predicate = NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS 'Scale' AND label CONTAINS %@",
            name, grams, kcal
        )
        return app.buttons.matching(predicate).firstMatch.exists
    }
}
