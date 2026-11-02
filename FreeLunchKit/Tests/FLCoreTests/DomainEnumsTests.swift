// SPDX-License-Identifier: GPL-3.0-or-later
// Every spec §1 enum is present with exactly the spec's cases, and every
// FLCore domain type is a Sendable value type.
import FLCore
import Foundation
import Testing

private func requireSendableValue<T: Sendable & Hashable & Codable>(_: T.Type) {}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode([T].self, from: JSONEncoder().encode([value]))[0]
}

@Suite("Spec §1 enums")
struct DomainEnumsTests {
    @Test("FoodOrigin")
    func foodOrigin() {
        #expect(FoodOrigin.allCases.map(\.rawValue) == ["seeded", "custom", "aiCreated", "labelOCR", "imported"])
    }

    @Test("MealState")
    func mealState() {
        #expect(MealState.allCases.map(\.rawValue) == ["draft", "logged"])
    }

    @Test("MealSource")
    func mealSource() {
        #expect(MealSource.allCases.map(\.rawValue) == ["phone", "watchQuickLog", "watchMarker", "healthKitImport"])
    }

    @Test("ItemProvenance")
    func itemProvenance() {
        #expect(ItemProvenance.allCases.map(\.rawValue) == ["typed", "scaleWeighed", "aiEstimate", "labelOCR", "imported"])
    }

    @Test("AIEstimationStatus")
    func aiEstimationStatus() {
        #expect(AIEstimationStatus.allCases.map(\.rawValue) == ["pending", "complete", "failed"])
    }

    @Test("PhotoKind")
    func photoKind() {
        #expect(PhotoKind.allCases.map(\.rawValue) == ["meal", "label"])
    }

    @Test("InjectionSite has the 8 rotation values")
    func injectionSite() {
        #expect(InjectionSite.allCases.map(\.rawValue) == [
            "abdomenLeft", "abdomenRight", "thighLeft", "thighRight",
            "armLeft", "armRight", "other1", "other2"
        ])
    }

    @Test("ShotSource")
    func shotSource() {
        #expect(ShotSource.allCases.map(\.rawValue) == ["phone", "watch", "shotsyImport"])
    }

    @Test("SideEffectType has 8 categories, other carrying text")
    func sideEffectType() throws {
        let all: [SideEffectType] = [
            .nausea, .vomiting, .constipation, .diarrhea,
            .fatigue, .appetiteLoss, .injectionSite, .other("headache")
        ]
        #expect(Set(all).count == 8)
        for value in all {
            #expect(try roundTrip(value) == value)
        }
        #expect(SideEffectType.other("a") != SideEffectType.other("b"))
    }

    @Test("CorrectionTargetKind")
    func correctionTargetKind() {
        #expect(CorrectionTargetKind.allCases.map(\.rawValue) == ["hkWeightSample", "hkNutritionDay", "importedShot"])
    }

    @Test("CorrectionAction")
    func correctionAction() {
        #expect(CorrectionAction.allCases.map(\.rawValue) == ["exclude", "replace"])
    }

    @Test("PlanStatus")
    func planStatus() {
        #expect(PlanStatus.allCases.map(\.rawValue) == ["pending", "done", "skipped"])
    }

    @Test("FormulaOrigin carries the builtin identifier")
    func formulaOrigin() throws {
        let all: [FormulaOrigin] = [.builtin("FL-EB v1"), .userEdited, .imported]
        #expect(Set(all).count == 3)
        for value in all {
            #expect(try roundTrip(value) == value)
        }
    }

    @Test("raw-valued enums decode from their persisted spelling")
    func rawValuesRoundTrip() throws {
        #expect(try roundTrip(FoodOrigin.labelOCR) == .labelOCR)
        #expect(try roundTrip(InjectionSite.other2) == .other2)
        let decoded = try JSONDecoder().decode([MealSource].self, from: Data(#"["watchMarker"]"#.utf8))
        #expect(decoded == [.watchMarker])
    }

    @Test("integer scales")
    func scales() {
        #expect(DomainScale.hunger == 1...5)
        #expect(DomainScale.sideEffectSeverity == 1...3)
    }

    @Test("known medication prefills")
    func knownMedications() {
        #expect(KnownMedication.allCases == [.semaglutide, .tirzepatide, .liraglutide])
        #expect(KnownMedication.allCases.map(\.halfLifeHours) == [168, 120, 13])
        #expect(KnownMedication.allCases.map(\.tmaxHours) == [36, 24, 11])
        let profile = MedicationProfileData(known: .liraglutide)
        #expect(profile.name == "Liraglutide")
        #expect(profile.halfLifeHours == 13)
        #expect(profile.tmaxHours == 11)
        #expect(profile.intervalDays == 7)
        #expect(profile.archivedAt == nil)
    }

    @Test("domain types are Sendable, Hashable, Codable values")
    func sendableValueTypes() {
        requireSendableValue(FoodOrigin.self)
        requireSendableValue(MealState.self)
        requireSendableValue(MealSource.self)
        requireSendableValue(ItemProvenance.self)
        requireSendableValue(AIEstimationStatus.self)
        requireSendableValue(PhotoKind.self)
        requireSendableValue(InjectionSite.self)
        requireSendableValue(ShotSource.self)
        requireSendableValue(SideEffectType.self)
        requireSendableValue(CorrectionTargetKind.self)
        requireSendableValue(CorrectionAction.self)
        requireSendableValue(PlanStatus.self)
        requireSendableValue(FormulaOrigin.self)
        requireSendableValue(KnownMedication.self)
        requireSendableValue(Grams.self)
        requireSendableValue(Kilograms.self)
        requireSendableValue(Kilocalories.self)
        requireSendableValue(Milligrams.self)
        requireSendableValue(ServingDef.self)
        requireSendableValue(NutritionValues.self)
        requireSendableValue(ShotEventData.self)
        requireSendableValue(MedicationProfileData.self)
    }
}
