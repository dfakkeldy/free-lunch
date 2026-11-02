// SPDX-License-Identifier: GPL-3.0-or-later
// Model → value mapping. The only place stored columns become FLCore types.
// Stored quantities were canonical when written (they entered through
// `Grams`, `Kilocalories` and `Milligrams`), so they are read back through
// the same types.
import FLCore
import Foundation

enum ServingsCoding {
    static func encode(_ servings: [ServingDef]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(servings)
    }

    static func decode(_ data: Data) throws -> [ServingDef] {
        try JSONDecoder().decode([ServingDef].self, from: data)
    }
}

enum SideEffectTypeCoding {
    static func kind(of type: SideEffectType) -> (kind: String, text: String?) {
        switch type {
        case .nausea: ("nausea", nil)
        case .vomiting: ("vomiting", nil)
        case .constipation: ("constipation", nil)
        case .diarrhea: ("diarrhea", nil)
        case .fatigue: ("fatigue", nil)
        case .appetiteLoss: ("appetiteLoss", nil)
        case .injectionSite: ("injectionSite", nil)
        case .other(let text): ("other", text)
        }
    }

    static func type(kind: String, text: String?) -> SideEffectType {
        switch kind {
        case "nausea": .nausea
        case "vomiting": .vomiting
        case "constipation": .constipation
        case "diarrhea": .diarrhea
        case "fatigue": .fatigue
        case "appetiteLoss": .appetiteLoss
        case "injectionSite": .injectionSite
        default: .other(text ?? "")
        }
    }
}

enum FormulaOriginCoding {
    static func kind(of origin: FormulaOrigin) -> (kind: String, builtinID: String?) {
        switch origin {
        case .builtin(let id): ("builtin", id)
        case .userEdited: ("userEdited", nil)
        case .imported: ("imported", nil)
        }
    }

    static func origin(kind: String, builtinID: String?) -> FormulaOrigin? {
        switch kind {
        case "builtin": builtinID.map { FormulaOrigin.builtin($0) }
        case "userEdited": .userEdited
        case "imported": .imported
        default: nil
        }
    }
}

extension NutritionValues {
    init(storedKcal kcal: Double, proteinG: Double, carbsG: Double, fatG: Double, fiberG: Double?) {
        self.init(
            kcal: Kilocalories(kcal),
            protein: Grams(proteinG),
            carbs: Grams(carbsG),
            fat: Grams(fatG),
            fiber: fiberG.map { Grams($0) }
        )
    }
}

extension FoodItem {
    func asData() throws -> FoodItemData {
        FoodItemData(
            id: id,
            name: name,
            brand: brand,
            per100g: NutritionValues(storedKcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG, fiberG: fiberG),
            isLiquid: isLiquid,
            servings: try ServingsCoding.decode(servingsJSON),
            origin: origin,
            useCount: useCount,
            lastUsedAt: lastUsedAt,
            lastPortion: lastPortionGrams.map { Grams($0) },
            archivedAt: archivedAt
        )
    }
}

extension Recipe {
    func asData() -> RecipeData {
        let ordered = components.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return RecipeData(
            id: id,
            name: name,
            components: ordered.compactMap { component in
                // A component always has a food: foods are never deleted.
                guard let food = component.foodItem else { return nil }
                return RecipeComponentData(id: component.id, foodID: food.id, grams: Grams(component.grams))
            },
            yield: Grams(yieldGrams)
        )
    }
}

extension PhotoAttachment {
    func asData() -> PhotoAttachmentData {
        PhotoAttachmentData(id: id, relativePath: relativePath, capturedAt: capturedAt, kind: kind)
    }
}

extension MealItem {
    func asData() -> MealItemData {
        MealItemData(
            id: id,
            order: order,
            foodID: foodItem?.id,
            adHocName: adHocName,
            quantity: Grams(quantityGrams),
            nutrition: NutritionValues(storedKcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG, fiberG: fiberG),
            provenance: provenance,
            aiRecordID: aiRecord?.id,
            confidence: confidence
        )
    }
}

extension MealEntry {
    func asData() -> MealEntryData {
        MealEntryData(
            id: id,
            state: state,
            createdAt: createdAt,
            loggedAt: loggedAt,
            items: items.map { $0.asData() }.sorted(by: MealItemData.displayOrder),
            hunger: hunger,
            note: note,
            photos: photos.map { $0.asData() }.sorted(by: PhotoAttachmentData.displayOrder),
            source: source
        )
    }
}

extension AIEstimationRecord {
    func asData() -> AIEstimationRecordData {
        AIEstimationRecordData(
            id: id,
            createdAt: createdAt,
            photoID: photo?.id,
            hint: hint,
            providerTier: providerTier,
            modelID: modelID,
            status: status,
            responseJSON: responseJSON,
            userCorrections: userCorrections
        )
    }
}

extension MedicationProfile {
    func asData() -> MedicationProfileData {
        MedicationProfileData(
            id: id,
            name: name,
            halfLifeHours: halfLifeHours,
            tmaxHours: tmaxHours,
            intervalDays: intervalDays,
            archivedAt: archivedAt
        )
    }
}

extension ShotEvent {
    /// Nil only for a shot whose profile link was lost, which the store
    /// never produces: profiles are archived, never deleted.
    func asData() -> ShotEventData? {
        guard let medication else { return nil }
        return ShotEventData(
            id: id,
            takenAt: takenAt,
            dose: Milligrams(doseMg),
            medicationID: medication.id,
            site: siteRaw.flatMap(InjectionSite.init(rawValue:)),
            note: note,
            source: source
        )
    }
}

extension SideEffectEntry {
    func asData() -> SideEffectEntryData {
        SideEffectEntryData(
            id: id,
            occurredAt: occurredAt,
            type: SideEffectTypeCoding.type(kind: typeKind, text: otherText),
            severity: severity,
            note: note
        )
    }
}

extension PlannedShot {
    func asData() -> PlannedShotData {
        PlannedShotData(
            id: id,
            plannedAt: plannedAt,
            notificationID: notificationID,
            status: status,
            fulfilledBy: fulfilledBy,
            dose: doseMg.map { Milligrams($0) }
        )
    }
}

extension PlannedMeal {
    func asData() -> PlannedMealData {
        PlannedMealData(
            id: id,
            plannedAt: plannedAt,
            notificationID: notificationID,
            status: status,
            fulfilledBy: fulfilledBy,
            name: name,
            note: note
        )
    }
}

extension JournalEntry {
    func asData() -> JournalEntryData {
        JournalEntryData(
            id: id,
            at: at,
            text: text,
            photos: photos.map { $0.asData() }.sorted(by: PhotoAttachmentData.displayOrder)
        )
    }
}
