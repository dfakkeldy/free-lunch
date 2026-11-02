// SPDX-License-Identifier: GPL-3.0-or-later
// Pure specification checks for the derived HealthKit weight view.
import FLCore
import Foundation
import Testing

private let correctedWeightAnchor = Date(timeIntervalSince1970: 1_767_600_000)

private func correctedWeightUID(_ number: Int) -> UUID {
    let digits = String(number)
    let padded = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
}

private func correctedWeightDate(_ days: Double) -> Date {
    correctedWeightAnchor.addingTimeInterval(days * 86_400)
}

private func correctedWeightSample(
    _ number: Int,
    day: Double = 0,
    kilograms: Double = 82,
    deletedInHK: Bool = false
) -> WeightSampleData {
    WeightSampleData(
        hkUUID: correctedWeightUID(number),
        measuredAt: correctedWeightDate(day),
        weight: Kilograms(kilograms),
        sourceBundleID: "com.example.scale",
        deletedInHK: deletedInHK
    )
}

private func correctedWeightCorrection(
    _ number: Int,
    target: UUID,
    day: Double = 0,
    action: CorrectionAction = .replace,
    replacement: Data? = nil,
    targetKind: CorrectionTargetKind = .hkWeightSample
) -> CorrectionData {
    CorrectionData(
        id: correctedWeightUID(number),
        createdAt: correctedWeightDate(day),
        targetKind: targetKind,
        targetID: target.uuidString,
        action: action,
        replacement: replacement
    )
}

@Suite("Corrected HealthKit weight view")
struct CorrectedWeightViewTests {
    @Test("deleted HealthKit samples never enter the view")
    func ignoresDeletedSamples() {
        let kept = correctedWeightSample(901, kilograms: 82.4)
        let deleted = correctedWeightSample(902, kilograms: 81.9, deletedInHK: true)

        let view = CorrectedWeightView.derive(samples: [deleted, kept], corrections: [])

        #expect(view.count == 1)
        #expect(view.first?.hkUUID == kept.hkUUID)
        #expect(view.first?.weightKg == 82.4)
        #expect(view.first?.correctionID == nil)
    }

    @Test("exclude and replace corrections derive a different view without a mutation")
    func excludesAndReplaces() throws {
        let first = correctedWeightSample(903, kilograms: 82.4)
        let second = correctedWeightSample(904, day: 1, kilograms: 82.1)
        let exclude = correctedWeightCorrection(905, target: first.hkUUID, action: .exclude)
        let replacement = try WeightSampleReplacement(weight: Kilograms(80.1), measuredAt: correctedWeightDate(3)).encoded()
        let replace = correctedWeightCorrection(906, target: second.hkUUID, day: 1, replacement: replacement)

        let view = CorrectedWeightView.derive(samples: [first, second], corrections: [exclude, replace])

        #expect(view == [
            CorrectedWeightSample(
                hkUUID: second.hkUUID,
                measuredAt: correctedWeightDate(3),
                weightKg: 80.1,
                sourceBundleID: "com.example.scale",
                correctionID: replace.id
            )
        ])
        #expect(first.weightKg == 82.4)
        #expect(second.weightKg == 82.1)
    }

    @Test("the newest valid correction wins and corrections do not stack")
    func newestWinsAndInvalidNewestIsIgnored() throws {
        let sample = correctedWeightSample(907, kilograms: 82.1)
        let older = correctedWeightCorrection(
            908,
            target: sample.hkUUID,
            replacement: try WeightSampleReplacement.encode(weight: Kilograms(80.1))
        )
        let newer = correctedWeightCorrection(
            909,
            target: sample.hkUUID,
            day: 1,
            replacement: try WeightSampleReplacement.encode(weight: Kilograms(79.9))
        )
        let malformedNewest = correctedWeightCorrection(
            910,
            target: sample.hkUUID,
            day: 2,
            replacement: Data("not a replacement".utf8)
        )

        let latest = CorrectedWeightView.derive(samples: [sample], corrections: [older, newer])
        #expect(latest.first?.weightKg == 79.9)
        #expect(latest.first?.correctionID == newer.id)

        let restoredOlder = CorrectedWeightView.derive(samples: [sample], corrections: [older])
        #expect(restoredOlder.first?.weightKg == 80.1)
        #expect(restoredOlder.first?.correctionID == older.id)

        let ignoresMalformed = CorrectedWeightView.derive(samples: [sample], corrections: [older, malformedNewest])
        #expect(ignoresMalformed.first?.weightKg == 80.1)
        #expect(ignoresMalformed.first?.correctionID == older.id)
    }

    @Test("unrelated and undecodable corrections are ignored")
    func ignoresUnmatchedCorrections() {
        let sample = correctedWeightSample(911, kilograms: 81.9)
        let unparsable = CorrectionData(
            id: correctedWeightUID(912),
            createdAt: correctedWeightDate(1),
            targetKind: .hkWeightSample,
            targetID: "not-a-uuid",
            action: .exclude
        )
        let wrongKind = correctedWeightCorrection(
            913,
            target: sample.hkUUID,
            action: .exclude,
            targetKind: .hkNutritionDay
        )
        let undecodable = correctedWeightCorrection(
            914,
            target: sample.hkUUID,
            day: 2,
            replacement: Data("{}".utf8)
        )

        let view = CorrectedWeightView.derive(samples: [sample], corrections: [unparsable, wrongKind, undecodable])

        #expect(view == [
            CorrectedWeightSample(
                hkUUID: sample.hkUUID,
                measuredAt: sample.measuredAt,
                weightKg: 81.9,
                sourceBundleID: "com.example.scale",
                correctionID: nil
            )
        ])
    }

    @Test("the view sorts by timestamp, then HealthKit UUID")
    func ordersSamplesDeterministically() {
        let latest = correctedWeightSample(917, day: 2, kilograms: 81.9)
        let sameTimeLaterID = correctedWeightSample(916, day: 1, kilograms: 82.1)
        let sameTimeEarlierID = correctedWeightSample(915, day: 1, kilograms: 82.4)

        let view = CorrectedWeightView.derive(
            samples: [latest, sameTimeLaterID, sameTimeEarlierID],
            corrections: []
        )

        #expect(view.map(\.hkUUID) == [sameTimeEarlierID.hkUUID, sameTimeLaterID.hkUUID, latest.hkUUID])
    }
}
