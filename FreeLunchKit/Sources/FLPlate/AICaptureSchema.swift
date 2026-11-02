// SPDX-License-Identifier: GPL-3.0-or-later
// Strict structured-output schema for spec §2 AI photo capture.
import Foundation
import CoreFoundation

public struct AICaptureItem: Sendable, Hashable, Codable {
    public let name: String
    public let estPortionGrams: Double
    public let kcal: Double
    public let protein: Double
    public let carbs: Double
    public let fat: Double
    public let confidence: Double

    public init(
        name: String,
        estPortionGrams: Double,
        kcal: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        confidence: Double
    ) {
        self.name = name
        self.estPortionGrams = estPortionGrams
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.confidence = confidence
    }
}

public struct AICaptureResponse: Sendable, Hashable, Codable {
    public let items: [AICaptureItem]
    public let note: String

    public init(items: [AICaptureItem], note: String) {
        self.items = items
        self.note = note
    }
}

public enum AICaptureFailure: Error, Equatable, Sendable, Codable {
    case notJSON
    case schemaMismatch
    case emptyItems
    case invalidValue(itemIndex: Int, field: String)
    case providerFailed

    public var userMessage: String {
        "Couldn't read this — log manually"
    }
}

/// Validates the provider's exact wire format before decoding it (spec §2).
public enum AICaptureParser {
    public static func parse(_ data: Data) -> Result<AICaptureResponse, AICaptureFailure> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.notJSON)
        }

        guard let responseObject = object as? [String: Any],
              Set(responseObject.keys) == ["items", "note"],
              responseObject["note"] is String,
              let rawItems = responseObject["items"] as? [Any]
        else {
            return .failure(.schemaMismatch)
        }

        guard !rawItems.isEmpty else { return .failure(.emptyItems) }
        let itemKeys: Set<String> = ["name", "estPortionGrams", "kcal", "protein", "carbs", "fat", "confidence"]
        for rawItem in rawItems {
            guard let item = rawItem as? [String: Any], Set(item.keys) == itemKeys,
                  item["name"] is String,
                  isJSONNumber(item["estPortionGrams"]),
                  isJSONNumber(item["kcal"]),
                  isJSONNumber(item["protein"]),
                  isJSONNumber(item["carbs"]),
                  isJSONNumber(item["fat"]),
                  isJSONNumber(item["confidence"])
            else {
                return .failure(.schemaMismatch)
            }
        }

        let response: AICaptureResponse
        do {
            response = try JSONDecoder().decode(AICaptureResponse.self, from: data)
        } catch {
            return .failure(.schemaMismatch)
        }

        for (index, item) in response.items.enumerated() {
            if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(.invalidValue(itemIndex: index, field: "name"))
            }
            if !item.estPortionGrams.isFinite || item.estPortionGrams <= 0 {
                return .failure(.invalidValue(itemIndex: index, field: "estPortionGrams"))
            }
            if !item.kcal.isFinite || item.kcal < 0 {
                return .failure(.invalidValue(itemIndex: index, field: "kcal"))
            }
            if !item.protein.isFinite || item.protein < 0 {
                return .failure(.invalidValue(itemIndex: index, field: "protein"))
            }
            if !item.carbs.isFinite || item.carbs < 0 {
                return .failure(.invalidValue(itemIndex: index, field: "carbs"))
            }
            if !item.fat.isFinite || item.fat < 0 {
                return .failure(.invalidValue(itemIndex: index, field: "fat"))
            }
            if !item.confidence.isFinite || !(0...1).contains(item.confidence) {
                return .failure(.invalidValue(itemIndex: index, field: "confidence"))
            }
        }
        return .success(response)
    }
}

func isJSONNumber(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) != CFBooleanGetTypeID()
}
