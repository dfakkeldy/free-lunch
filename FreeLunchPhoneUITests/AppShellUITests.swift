// SPDX-License-Identifier: GPL-3.0-or-later
// The app shell on the real app: three tabs — Timeline, Insights, Library —
// with Timeline selected at launch, the settings gear opening the settings
// sheet from each tab's root, and the four Library sections pushing their
// own placeholder screens without the gear.

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

        // Timeline is the default: its empty state is on screen at launch.
        XCTAssertTrue(app.staticTexts["phone.emptyState.heading"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsGearOpensSettingsFromEveryTab() {
        continueAfterFailure = false
        let app = launch()

        for tab in ["Timeline", "Insights", "Library"] {
            let tabButton = app.tabBars.buttons[tab]
            XCTAssertTrue(tabButton.waitForExistence(timeout: 15))
            tabButton.tap()

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
    func testLibrarySectionsPushWithoutTheGear() {
        continueAfterFailure = false
        let app = launch()

        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "library-sections"
        shot.lifetime = .keepAlways
        add(shot)

        let sections = [
            ("library.foods", "Foods"),
            ("library.recipes", "Recipes"),
            ("library.formulas", "Formulas"),
            ("library.medications", "Medications"),
        ]
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
