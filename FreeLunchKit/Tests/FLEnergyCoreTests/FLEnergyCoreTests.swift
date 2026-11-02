// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import FLEnergyCore

@Suite("FLEnergyCore compiles and links")
struct FLEnergyCoreTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(FLEnergyCore.placeholder == "FLEnergyCore")
    }
}
