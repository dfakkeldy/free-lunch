// SPDX-License-Identifier: GPL-3.0-or-later
// Pins the flat 7-day default dosing interval (DECISIONS 2026-11-03).
import Foundation
import Testing
@testable import FLCore

@Suite("Medication default interval")
struct MedicationIntervalDefaultTests {
    @Test("Default constant is 7 days")
    func defaultConstant() {
        #expect(MedicationProfileData.defaultIntervalDays == 7)
    }

    @Test("Every known-medication prefill resolves to the flat default")
    func knownPrefillsUseDefault() {
        for known in KnownMedication.allCases {
            let profile = MedicationProfileData(known: known)
            #expect(profile.intervalDays == MedicationProfileData.defaultIntervalDays)
            #expect(profile.intervalDays == 7)
        }
        #expect(KnownMedication.allCases.count == 3)
    }

    @Test("A custom profile resolves to the flat default")
    func customUsesDefault() {
        let profile = MedicationProfileData(name: "Custom", halfLifeHours: 100, tmaxHours: 20)
        #expect(profile.intervalDays == 7)
    }

    @Test("The interval stays editable per profile")
    func intervalEditable() {
        var known = MedicationProfileData(known: .liraglutide)
        known.intervalDays = 1
        #expect(known.intervalDays == 1)
        var custom = MedicationProfileData(name: "Custom", halfLifeHours: 100, tmaxHours: 20)
        custom.intervalDays = 14
        #expect(custom.intervalDays == 14)
        #expect(MedicationProfileData(known: .liraglutide, intervalDays: 3).intervalDays == 3)
        #expect(MedicationProfileData.defaultIntervalDays == 7)
    }
}
