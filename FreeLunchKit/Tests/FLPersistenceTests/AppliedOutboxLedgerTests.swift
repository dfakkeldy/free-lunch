// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §9 sync spine: the phone's applied-outbox ledger (AppliedOutboxRecord)
// as the SwiftData store keeps it. Its shape, the record/contains round
// trip, survival across a cold reopen of the same file, and the watch
// store's refusal. The coordinator's use of it is in WatchSyncSpineTests.
// Every id and date is synthetic.
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

@MainActor
@Suite("Spec §9: applied-outbox ledger store lane")
struct AppliedOutboxLedgerTests {
    @Test("the ledger row is a unique id and an applied-at date, nothing more")
    func ledgerShape() throws {
        let schema = Schema(versionedSchema: FreeLunchSchemaV2.self)
        let entity = try #require(schema.entities.first { $0.name == "AppliedOutboxRecord" })
        let optionality = Dictionary(uniqueKeysWithValues: entity.attributes.map { ($0.name, $0.isOptional) })
        #expect(optionality == ["id": false, "appliedAt": false])
        #expect(entity.relationships.isEmpty)
        #expect(Set(entity.attributes.filter(\.isUnique).map(\.name)) == ["id"])
    }

    @Test("record then contains; a second record of the same id keeps the first row")
    func roundTrip() throws {
        let store = try SwiftDataStore.phone(at: .inMemory)
        #expect(try !store.hasAppliedOutboxItem(id: uid(83_001)))

        try store.recordAppliedOutboxItem(id: uid(83_001), appliedAt: at(hour: 1))
        #expect(try store.hasAppliedOutboxItem(id: uid(83_001)))
        #expect(try !store.hasAppliedOutboxItem(id: uid(83_002)))

        try store.recordAppliedOutboxItem(id: uid(83_001), appliedAt: at(hour: 2))
        try store.recordAppliedOutboxItem(id: uid(83_002), appliedAt: at(hour: 3))
        #expect(try store.hasAppliedOutboxItem(id: uid(83_002)))
        let rows = try store.context.fetch(FetchDescriptor<AppliedOutboxRecord>())
        let appliedAt = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.appliedAt) })
        #expect(appliedAt == [uid(83_001): at(hour: 1), uid(83_002): at(hour: 3)])
    }

    @Test("recorded ids survive a cold reopen of the same store file")
    func persistsAcrossReopen() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        do {
            let store = try SwiftDataStore.phone(at: .file(url))
            try store.recordAppliedOutboxItem(id: uid(83_011), appliedAt: at(day: 1))
            try store.recordAppliedOutboxItem(id: uid(83_012), appliedAt: at(day: 2))
        }

        let reopened = try SwiftDataStore.phone(at: .file(url))
        #expect(try reopened.hasAppliedOutboxItem(id: uid(83_011)))
        #expect(try reopened.hasAppliedOutboxItem(id: uid(83_012)))
        #expect(try !reopened.hasAppliedOutboxItem(id: uid(83_013)))
        #expect(try reopened.rowCount(AppliedOutboxRecord.self) == 2)
    }

    @Test("the watch store refuses every ledger operation and stores nothing")
    func watchRefuses() throws {
        let watch = try SwiftDataStore.watch(at: .inMemory)
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("hasAppliedOutboxItem")) {
            try watch.hasAppliedOutboxItem(id: uid(83_021))
        }
        #expect(throws: FreeLunchStoreError.phoneOnlyOperation("recordAppliedOutboxItem")) {
            try watch.recordAppliedOutboxItem(id: uid(83_021), appliedAt: at())
        }
        #expect(try watch.rowCount(AppliedOutboxRecord.self) == 0)
    }
}
