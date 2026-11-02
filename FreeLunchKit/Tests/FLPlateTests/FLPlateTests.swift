// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import FLPlate

@Suite("FLPlate compiles and links")
struct FLPlateTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(FLPlate.placeholder == "FLPlate")
    }
}
