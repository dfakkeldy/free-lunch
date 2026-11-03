// SPDX-License-Identifier: GPL-3.0-or-later
// The app shell on the real app: three tabs — Timeline, Insights, Library —
// in that order, with Timeline selected at launch, the settings gear opening
// the settings sheet from each tab's root, and neither the plate nor the four
// Library sections (in their order) carrying the gear.

import XCTest

final class AppShellUITests: XCTestCase {
    @MainActor
    func testThreeTabsOpenOnTimeline() {
        continueAfterFailure = false
        let app = launch()

        let timeline = app.tabBars.buttons["Timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Insights"].exists)
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertEqual(
            (0..<3).map { app.tabBars.buttons.element(boundBy: $0).label },
            ["Timeline", "Insights", "Library"]
        )

        // Timeline is the default: its empty state is on screen at launch.
        XCTAssertTrue(app.staticTexts["phone.emptyState.heading"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsGearOpensSettingsFromEveryTab() {
        continueAfterFailure = false
        let app = launch()

        // Each tab's root title, so the gear is only looked for once the tab
        // has switched.
        for (tab, rootTitle) in [("Timeline", "Today"), ("Insights", "Insights"), ("Library", "Library")] {
            let tabButton = app.tabBars.buttons[tab]
            XCTAssertTrue(tabButton.waitForExistence(timeout: 15))
            tabButton.tap()
            XCTAssertTrue(app.navigationBars[rootTitle].waitForExistence(timeout: 10), "\(tab) did not open")

            let gear = app.buttons["nav.settings"]
            XCTAssertTrue(gear.waitForExistence(timeout: 10), "No settings gear on \(tab)")
            gear.tap()

            let settings = app.navigationBars["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings did not open from \(tab)")

            let done = app.buttons["settings.done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 10), "Settings did not dismiss from \(tab)")
        }
    }

    @MainActor
    func testPlateHasNoGearOrTabBar() {
        continueAfterFailure = false
        let app = launch()

        let log = app.buttons["timeline.log"]
        XCTAssertTrue(log.waitForExistence(timeout: 15))
        log.tap()
        XCTAssertTrue(app.staticTexts["plate.total"].waitForExistence(timeout: 10))

        // The gear is on the Timeline root only, and the plate keeps the
        // whole screen (DECISIONS.md, 2026-11-03).
        XCTAssertTrue(
            app.buttons["nav.settings"].waitForNonExistence(timeout: 5),
            "The settings gear showed on the plate"
        )
        let tabBar = app.tabBars.firstMatch
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "The tab bar showed on the plate")
    }

    @MainActor
    func testLibrarySectionsPushWithoutTheGear() {
        continueAfterFailure = false
        let app = launch()

        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))

        let sections = [
            ("library.foods", "Foods"),
            ("library.recipes", "Recipes"),
            ("library.formulas", "Formulas"),
            ("library.medications", "Medications"),
        ]

        // The rows run top to bottom in this order.
        let rowTops = sections.map { identifier, title in
            let row = app.buttons[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Missing the \(title) row")
            return row.frame.minY
        }
        XCTAssertEqual(rowTops, rowTops.sorted(), "The Library rows are out of order")

        for (identifier, title) in sections {
            let row = app.buttons[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Missing the \(title) row")
            row.tap()

            let pushed = app.navigationBars[title]
            XCTAssertTrue(pushed.waitForExistence(timeout: 10), "\(title) did not open")
            // The gear is on the Library root only. Waiting lets the root's
            // bar finish leaving with the push animation.
            XCTAssertTrue(
                app.buttons["nav.settings"].waitForNonExistence(timeout: 5),
                "The settings gear showed on \(title)"
            )

            pushed.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launchArguments += ["-FLUITestInMemoryStore"]
        app.launch()
        return app
    }
}
