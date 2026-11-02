// SPDX-License-Identifier: GPL-3.0-or-later
// Strict label-OCR parsing and draft construction for spec §2.
import Foundation
import FLCore

public enum LabelOCRFailure: Error, Equatable, Sendable {
    case notJSON
    case schemaMismatch
    case invalidValue(field: String)

    public var userMessage: String {
        "Couldn't read this — log manually"
    }
}

public struct FoodItemDraft: Sendable, Hashable {
    public let name: String
    public let brand: String?
    public let per100g: NutritionValues
    public let isLiquid: Bool
    public let servings: [ServingDef]
    public let origin: FoodOrigin

    public init(
        name: String,
        brand: String?,
        per100g: NutritionValues,
        isLiquid: Bool,
        servings: [ServingDef],
        origin: FoodOrigin
    ) {
        self.name = name
        self.brand = brand
        self.per100g = per100g
        self.isLiquid = isLiquid
        self.servings = servings
        self.origin = origin
    }
}

/// Parses exactly the label response contract in spec §2.
public enum LabelOCRParser {
    public static func parse(_ data: Data) -> Result<FoodItemDraft, LabelOCRFailure> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.notJSON)
        }
        guard let dictionary = object as? [String: Any] else {
            return .failure(.schemaMismatch)
        }
        let required: Set<String> = ["name", "servingSizeGrams", "kcal", "protein", "carbs", "fat"]
        let allowed = required.union(["brand", "servingName", "fiber"])
        guard required.isSubset(of: dictionary.keys), Set(dictionary.keys).isSubset(of: allowed),
              dictionary["name"] is String,
              isJSONNumber(dictionary["servingSizeGrams"]),
              isJSONNumber(dictionary["kcal"]),
              isJSONNumber(dictionary["protein"]),
              isJSONNumber(dictionary["carbs"]),
              isJSONNumber(dictionary["fat"]),
              validOptionalString(dictionary["brand"]),
              validOptionalString(dictionary["servingName"]),
              validOptionalNumber(dictionary["fiber"])
        else {
            return .failure(.schemaMismatch)
        }

        let name = dictionary["name"] as! String
        let servingSize = (dictionary["servingSizeGrams"] as! NSNumber).doubleValue
        let kcal = (dictionary["kcal"] as! NSNumber).doubleValue
        let protein = (dictionary["protein"] as! NSNumber).doubleValue
        let carbs = (dictionary["carbs"] as! NSNumber).doubleValue
        let fat = (dictionary["fat"] as! NSNumber).doubleValue
        let fiber = (dictionary["fiber"] as? NSNumber).map(\.doubleValue)

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.invalidValue(field: "name"))
        }
        if !servingSize.isFinite || servingSize <= 0 {
            return .failure(.invalidValue(field: "servingSizeGrams"))
        }
        for (field, value) in [("kcal", kcal), ("protein", protein), ("carbs", carbs), ("fat", fat)] {
            if !value.isFinite || value < 0 { return .failure(.invalidValue(field: field)) }
        }
        if let fiber, (!fiber.isFinite || fiber < 0) {
            return .failure(.invalidValue(field: "fiber"))
        }

        let multiplier = 100 / servingSize
        let per100Kcal = kcal * multiplier
        let per100Protein = protein * multiplier
        let per100Carbs = carbs * multiplier
        let per100Fat = fat * multiplier
        let per100Fiber = fiber.map { $0 * multiplier }
        guard per100Kcal.isFinite, per100Protein.isFinite, per100Carbs.isFinite, per100Fat.isFinite,
              per100Fiber?.isFinite ?? true
        else { return .failure(.invalidValue(field: "servingSizeGrams")) }

        return .success(FoodItemDraft(
            name: name,
            brand: dictionary["brand"] as? String,
            per100g: NutritionValues(
                kcal: Kilocalories(per100Kcal),
                protein: Grams(per100Protein),
                carbs: Grams(per100Carbs),
                fat: Grams(per100Fat),
                fiber: per100Fiber.map(Grams.init)
            ),
            isLiquid: false,
            servings: [ServingDef(name: (dictionary["servingName"] as? String) ?? "1 serving", grams: Grams(servingSize))],
            origin: .labelOCR
        ))
    }
}

extension FoodItemDraft {
    public func plateItem(id: UUID, grams: Double) -> CapturePlateItem? {
        guard grams.isFinite, grams > 0 else { return nil }
        let multiplier = grams / 100
        let kcal = per100g.kcal * multiplier
        let protein = per100g.proteinG * multiplier
        let carbs = per100g.carbsG * multiplier
        let fat = per100g.fatG * multiplier
        let fiber = per100g.fiberG.map { $0 * multiplier }
        guard kcal.isFinite, protein.isFinite, carbs.isFinite, fat.isFinite,
              fiber?.isFinite ?? true
        else { return nil }
        return CapturePlateItem(
            id: id,
            name: name,
            quantityGrams: grams,
            nutrition: NutritionValues(
                kcal: Kilocalories(kcal),
                protein: Grams(protein),
                carbs: Grams(carbs),
                fat: Grams(fat),
                fiber: fiber.map(Grams.init)
            ),
            provenance: .labelOCR,
            aiRecordID: nil,
            confidence: nil,
            userEdited: false
        )
    }
}

extension CapturePlate {
    /// Parses a label record into a draft only; it never auto-adds to the plate (spec §2).
    public mutating func applyLabelResponse(_ data: Data, toRecord recordID: UUID) -> FoodItemDraft? {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].kind == .label
        else { return nil }
        switch LabelOCRParser.parse(data) {
        case .success(let draft):
            records[index].status = .complete
            records[index].responseJSON = data
            records[index].failure = nil
            return draft
        case .failure(let failure):
            let captureFailure: AICaptureFailure = switch failure {
            case .notJSON: .notJSON
            case .schemaMismatch: .schemaMismatch
            case .invalidValue(let field): .invalidValue(itemIndex: 0, field: field)
            }
            failRecord(at: index, with: captureFailure)
            return nil
        }
    }
}

private func validOptionalString(_ value: Any?) -> Bool {
    value == nil || value is NSNull || value is String
}

private func validOptionalNumber(_ value: Any?) -> Bool {
    value == nil || value is NSNull || isJSONNumber(value)
}
