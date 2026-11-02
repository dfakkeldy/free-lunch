// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLPlate

@Suite("AI capture schema")
struct AICaptureSchemaTests {
    @Test("a valid two-item response preserves all portion values")
    func parsesValidResponse() {
        let result = AICaptureParser.parse(json("""
        {"items":[
          {"name":"Rice","estPortionGrams":150,"kcal":195,"protein":4,"carbs":42,"fat":0.5,"confidence":0.8},
          {"name":"Beans","estPortionGrams":85,"kcal":110,"protein":7,"carbs":20,"fat":0.4,"confidence":0.55}
        ],"note":"synthetic estimate"}
        """))
        guard case .success(let response) = result else {
            Issue.record("Expected a parsed response")
            return
        }
        #expect(response.note == "synthetic estimate")
        #expect(response.items.count == 2)
        #expect(response.items[0] == AICaptureItem(name: "Rice", estPortionGrams: 150, kcal: 195, protein: 4, carbs: 42, fat: 0.5, confidence: 0.8))
        #expect(response.items[1] == AICaptureItem(name: "Beans", estPortionGrams: 85, kcal: 110, protein: 7, carbs: 20, fat: 0.4, confidence: 0.55))
    }

    @Test("strict wire-shape rejections")
    func rejectsWrongShapesAndTypes() {
        let cases: [(String, AICaptureFailure)] = [
            ("not json", .notJSON),
            ("[]", .schemaMismatch),
            ("{\"items\":[]}", .schemaMismatch),
            ("{\"items\":[],\"note\":\"x\",\"extra\":1}", .schemaMismatch),
            ("{\"items\":[{\"name\":\"x\",\"estPortionGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1}],\"note\":\"x\"}", .schemaMismatch),
            ("{\"items\":[{\"name\":\"x\",\"estPortionGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":0.5,\"extra\":0}],\"note\":\"x\"}", .schemaMismatch),
            ("{\"items\":[{\"name\":\"x\",\"estPortionGrams\":\"1\",\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":0.5}],\"note\":\"x\"}", .schemaMismatch),
            ("{\"items\":[],\"note\":\"x\"}", .emptyItems),
            ("{\"items\":[{\"name\":\"x\",\"estPortionGrams\":true,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":0.5}],\"note\":\"x\"}", .schemaMismatch)
        ]
        for (source, expected) in cases {
            #expect(AICaptureParser.parse(json(source)) == .failure(expected))
        }
    }

    @Test("value rejections are atomic and name their first invalid field")
    func rejectsInvalidValues() {
        let prefix = "{\"items\":[{\"name\":\"good\",\"estPortionGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":0.5},"
        let suffix = "],\"note\":\"x\"}"
        let cases: [(String, AICaptureFailure)] = [
            (prefix + "{\"name\":\"   \",\"estPortionGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":0.5}" + suffix, .invalidValue(itemIndex: 1, field: "name")),
            ("{\"items\":[{\"name\":\"x\",\"estPortionGrams\":0,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":0.5}],\"note\":\"x\"}", .invalidValue(itemIndex: 0, field: "estPortionGrams")),
            ("{\"items\":[{\"name\":\"x\",\"estPortionGrams\":1,\"kcal\":-1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":0.5}],\"note\":\"x\"}", .invalidValue(itemIndex: 0, field: "kcal")),
            ("{\"items\":[{\"name\":\"x\",\"estPortionGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":1.2}],\"note\":\"x\"}", .invalidValue(itemIndex: 0, field: "confidence")),
            ("{\"items\":[{\"name\":\"x\",\"estPortionGrams\":1,\"kcal\":1,\"protein\":1,\"carbs\":1,\"fat\":1,\"confidence\":-0.1}],\"note\":\"x\"}", .invalidValue(itemIndex: 0, field: "confidence"))
        ]
        for (source, expected) in cases {
            #expect(AICaptureParser.parse(json(source)) == .failure(expected))
        }
    }

    @Test("confidence boundaries are accepted")
    func acceptsConfidenceBoundaries() {
        let data = json("""
        {"items":[
          {"name":"zero","estPortionGrams":1,"kcal":0,"protein":0,"carbs":0,"fat":0,"confidence":0},
          {"name":"one","estPortionGrams":1,"kcal":0,"protein":0,"carbs":0,"fat":0,"confidence":1}
        ],"note":""}
        """)
        guard case .success(let response) = AICaptureParser.parse(data) else {
            Issue.record("Expected confidence boundaries to parse")
            return
        }
        #expect(response.items[0].confidence == 0)
        #expect(response.items[1].confidence == 1)
    }
}

private func json(_ source: String) -> Data {
    Data(source.utf8)
}
