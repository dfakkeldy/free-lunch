// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 amendment: DietarySampleMirror's shape and its store lane
// (keyed upsert, deletedInHK flagging, day-range reads, phone store only).
// HealthKit itself is not involved; every sample here is synthetic.
import FLCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §1 amendment: DietarySampleMirror store lane")
struct DietaryStoreTests {
    private func sample(
        _ n: Int,
        at date: Date,
        kcal: Double = 500,
        protein: Double? = 30,
        carbs: Double? = 55,
        fat: Double? = 18,
        deleted: Bool = false
    ) -> DietarySampleData {
        DietarySampleData(
            hkUUID: uid(n),
            date: date,
            energy: Kilocalories(kcal),
            protein: protein.map { Grams($0) },
            carbs: carbs.map { Grams($0) },
            fat: fat.map { Grams($0) },
            sourceBundleID: "com.example.synthetic.diary",
            deletedInHK: deleted
        )
    }

    @Test("the mirror's fields are exactly the amendment's")
    func mirrorShape() throws {
        let schema = Schema(versionedSchema: FreeLunchSchemaV2.self)
        let entity = try #require(schema.entities.first { $0.name == "DietarySampleMirror" })
        let optionality = Dictionary(uniqueKeysWithValues: entity.attributes.map { ($0.name, $0.isOptional) })
        #expect(optionality == [
            "hkUUID": false, "date": false, "kcal": false,
            "proteinG": true, "carbsG": true, "fatG": true,
            "sourceBundleID": false, "deletedInHK": false
        ])
        #expect(entity.relationships.isEmpty)
        #expect(entity.uniquenessConstraints == [["hkUUID"]])

        // Swift types, checked at compile time.
        let row = DietarySampleMirror(
            hkUUID: uid(1), date: at(), kcal: 1, proteinG: nil, carbsG: nil, fatG: nil,
            sourceBundleID: "x", deletedInHK: false
        )
        let _: UUID = row.hkUUID
        let _: Date = row.date
        let _: Double = row.kcal
        let _: Double? = row.proteinG
        let _: Double? = row.carbsG
        let _: Double? = row.fatG
        let _: String = row.sourceBundleID
        let _: Bool = row.deletedInHK
    }

    @Test("upsert inserts, then overwrites by hkUUID without a second row")
    func keyedUpsert() throws {
        let store = try makeInMemoryStore()
        let first = sample(82_001, at: at(hour: 2))
        try store.upsertDietarySample(first)
        #expect(try store.rowCount(DietarySampleMirror.self) == 1)

        let revised = sample(82_001, at: at(hour: 3), kcal: 620, protein: nil, carbs: 70, fat: nil)
        try store.upsertDietarySample(revised)
        #expect(try store.rowCount(DietarySampleMirror.self) == 1)
        #expect(try store.dietarySamples(from: at(), through: at(), calendar: utcCalendar) == [revised])

        try store.upsertDietarySample(sample(82_002, at: at(hour: 4)))
        #expect(try store.rowCount(DietarySampleMirror.self) == 2)
    }

    @Test("deletedInHK flags the row, hides it by default and keeps it on request")
    func deletedInHKFlagging() throws {
        let store = try makeInMemoryStore()
        let kept = sample(82_011, at: at(hour: 1))
        let gone = sample(82_012, at: at(hour: 2))
        try store.upsertDietarySample(kept)
        try store.upsertDietarySample(gone)

        try store.markDietarySampleDeletedInHK(hkUUID: gone.hkUUID)
        #expect(try store.rowCount(DietarySampleMirror.self) == 2)
        #expect(try store.dietarySamples(from: at(), through: at(), calendar: utcCalendar) == [kept])
        var flagged = gone
        flagged.deletedInHK = true
        #expect(
            try store.dietarySamples(from: at(), through: at(), calendar: utcCalendar, includingDeletedInHK: true)
                == [kept, flagged]
        )

        #expect(throws: FreeLunchStoreError.notFound(uid(82_019))) {
            try store.markDietarySampleDeletedInHK(hkUUID: uid(82_019))
        }
    }

    @Test("an upsert carrying deletedInHK stores it as given")
    func upsertCarriesDeletedFlag() throws {
        let store = try makeInMemoryStore()
        try store.upsertDietarySample(sample(82_021, at: at(), deleted: true))
        #expect(try store.dietarySamples(from: at(), through: at(), calendar: utcCalendar).isEmpty)
        try store.upsertDietarySample(sample(82_021, at: at(), deleted: false))
        #expect(try store.dietarySamples(from: at(), through: at(), calendar: utcCalendar).map(\.hkUUID) == [uid(82_021)])
    }

    @Test("day range: whole calendar days first through last, oldest first")
    func dayRange() throws {
        let store = try makeInMemoryStore()
        // `anchor` is 08:00 UTC, so hour -8 is midnight starting day 0.
        let dayStart = at(hour: -8)
        let beforeRange = sample(82_031, at: dayStart.addingTimeInterval(-1))
        let firstInstant = sample(82_032, at: dayStart)
        let laterSameTime = sample(82_034, at: at(day: 1, hour: 3))
        let earlierUUIDSameTime = sample(82_033, at: at(day: 1, hour: 3))
        let lastInstant = sample(82_035, at: dayStart.addingTimeInterval(3 * 86_400 - 1))
        let afterRange = sample(82_036, at: dayStart.addingTimeInterval(3 * 86_400))
        for row in [afterRange, laterSameTime, beforeRange, lastInstant, firstInstant, earlierUUIDSameTime] {
            try store.upsertDietarySample(row)
        }

        // Any instant inside the first and last days selects the whole days.
        let range = try store.dietarySamples(from: at(hour: 10), through: at(day: 2, hour: 1), calendar: utcCalendar)
        #expect(range == [firstInstant, earlierUUIDSameTime, laterSameTime, lastInstant])

        #expect(try store.dietarySamples(from: at(day: 1), through: at(day: 1), calendar: utcCalendar)
            == [earlierUUIDSameTime, laterSameTime])
        #expect(try store.dietarySamples(from: at(day: 2), through: at(day: 1), calendar: utcCalendar).isEmpty)
    }

    @Test("day bounds follow the calendar passed in")
    func dayRangeUsesCalendar() throws {
        let store = try makeInMemoryStore()
        var plusFive = Calendar(identifier: .gregorian)
        plusFive.timeZone = TimeZone(secondsFromGMT: 5 * 3_600)!
        // 20:00 UTC on day 0 is 01:00 on day 1 at UTC+5.
        let evening = sample(82_041, at: at(hour: 12))
        try store.upsertDietarySample(evening)
        #expect(try store.dietarySamples(from: at(), through: at(), calendar: utcCalendar) == [evening])
        #expect(try store.dietarySamples(from: at(), through: at(), calendar: plusFive).isEmpty)
        #expect(try store.dietarySamples(from: at(day: 1), through: at(day: 1), calendar: plusFive) == [evening])
    }

    @Test("a corrupt stored quantity is refused on read")
    func corruptRowRefused() throws {
        let store = try makeInMemoryStore()
        store.context.insert(
            DietarySampleMirror(
                hkUUID: uid(82_051), date: at(), kcal: -1, proteinG: nil, carbsG: nil, fatG: nil,
                sourceBundleID: "com.example.synthetic.diary", deletedInHK: false
            )
        )
        try store.context.save()
        #expect(throws: DietaryStoreError.invalidStoredSample(uid(82_051))) {
            try store.dietarySamples(from: at(), through: at(), calendar: utcCalendar)
        }
    }

    @Test("the mirror survives a cold reopen of the phone store file")
    func coldReopen() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let row = sample(82_061, at: at(day: 3), protein: nil)
        do {
            let store = try SwiftDataStore.phone(at: .file(url))
            try store.upsertDietarySample(row)
        }
        let reopened = try SwiftDataStore.phone(at: .file(url))
        #expect(try reopened.dietarySamples(from: at(day: 3), through: at(day: 3), calendar: utcCalendar) == [row])
    }

    @Test("the watch store refuses every mirror operation and stores nothing")
    func watchRefuses() throws {
        let watch = try SwiftDataStore.watch(at: .inMemory)
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("upsertDietarySample")) {
            try watch.upsertDietarySample(sample(82_071, at: at()))
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("markDietarySampleDeletedInHK")) {
            try watch.markDietarySampleDeletedInHK(hkUUID: uid(82_071))
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("dietarySamples")) {
            try watch.dietarySamples(from: at(), through: at(), calendar: utcCalendar)
        }
        #expect(try watch.rowCount(DietarySampleMirror.self) == 0)
    }
}
