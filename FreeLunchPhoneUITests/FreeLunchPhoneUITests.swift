// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

final class FreeLunchPhoneUITests: XCTestCase {
    func testLaunchShowsPlaceholderEmptyState() {
        let app = XCUIApplication(bundleIdentifier: "com.freelunch.nutrition")
        app.launch()

        let heading = app.staticTexts["phone.emptyState.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 15))
        XCTAssertEqual(heading.label, "Nothing logged yet")
    }
}
