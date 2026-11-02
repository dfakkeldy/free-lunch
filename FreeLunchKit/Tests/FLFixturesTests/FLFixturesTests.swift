// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import FLFixtures

@Suite("FLFixtures compiles and links")
struct FLFixturesTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(FLFixtures.placeholder == "FLFixtures")
    }
}
