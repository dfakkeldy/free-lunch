// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import FLPersistence

@Suite("FLPersistence compiles and links")
struct FLPersistenceTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(FLPersistence.placeholder == "FLPersistence")
    }
}
