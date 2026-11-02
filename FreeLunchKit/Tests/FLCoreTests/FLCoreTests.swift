// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import FLCore

@Suite("FLCore compiles and links")
struct FLCoreTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(FLCore.placeholder == "FLCore")
    }
}
