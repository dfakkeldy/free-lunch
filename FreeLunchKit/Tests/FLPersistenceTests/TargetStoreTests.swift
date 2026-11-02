// SPDX-License-Identifier: GPL-3.0-or-later
// The target lane: FormulaVersion and TargetPeriod records, adoption closing
// and opening periods, refusals, and validation on load (spec §1, §3).
import FLCore
import FLEnergyCore
import Foundation
import SwiftData
import Testing
@testable import FLPersistence

private typealias E = EnergyStoreFixture

/// expenditure 2400, rate −0.5 kg/wk at ρ 7700 → 2400 − 550 = 1850.
private let calculatedV1 = CalculatedTarget(expenditureKcal: 2_400, rateGoal: E.rate(-0.5))

private func adoption(
    _ calculated: CalculatedTarget = calculatedV1,
    adopted: Double? = nil,
    formula: EnergyFormulaVersion = .builtinV1
) -> TargetAdoption {
    TargetAdoption(calculated: calculated, adoptedTargetKcal: adopted, macros: E.macros(), formula: formula)
}

@MainActor
private func storeWithFormulas() throws -> SwiftDataStore {
    let store = try makeInMemoryStore()
    try store.registerFormulaVersion(E.v1Row)
    try store.registerFormulaVersion(E.v2Row)
    return store
}

@MainActor
@Suite("Target lane: formula version records")
struct FormulaVersionRecordTests {
    @Test("versions round-trip with origin, parameters and definition, through a reopened file")
    func roundTrip() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let edited = StoredFormulaVersion(
            id: uid(9_003),
            formula: EnergyFormulaVersion(
                name: "My copy",
                origin: .userEdited,
                parameters: ExpenditureParameters(energyDensityKcalPerKg: 7_200)!
            ),
            definition: "intake_mean - (trend_delta * rho / window_days)",
            createdAt: E.day(29)
        )
        let imported = StoredFormulaVersion(
            id: uid(9_004),
            formula: EnergyFormulaVersion(
                name: "Shared formula",
                origin: .imported,
                parameters: ExpenditureParameters(energyDensityKcalPerKg: 7_700)!
            ),
            definition: "intake_mean",
            createdAt: E.day(29)
        )
        do {
            let store = try SwiftDataStore.phone(at: .file(url))
            for version in [imported, E.v2Row, edited, E.v1Row] {
                try store.registerFormulaVersion(version)
            }
        }
        let store = try SwiftDataStore.phone(at: .file(url))
        // By createdAt, then id (9003 before 9004 on day 29).
        #expect(try store.formulaVersions() == [E.v1Row, E.v2Row, edited, imported])
        #expect(try store.formulaVersion(id: E.v2Row.id) == E.v2Row)
        #expect(try store.formulaVersion(id: uid(1)) == nil)
        #expect(try store.formulaVersion(id: E.v1Row.id)?.definition == "intake_mean - (trend_delta * rho / window_days)")

        // The row stores FLCore's origin coding and ρ as JSON.
        let row = try #require(try store.context.fetch(FetchDescriptor<FormulaVersion>()).first { $0.id == E.v2Row.id })
        #expect(row.originKind == "builtin")
        #expect(row.builtinID == "FL-EB v2")
        #expect(row.paramsJSON == Data(#"{"energyDensityKcalPerKg":7000}"#.utf8))
    }

    @Test("a duplicate id or an equal version is refused and nothing is written")
    func duplicates() throws {
        let store = try storeWithFormulas()
        #expect(throws: FreeLunchStoreError.duplicateID(E.v1Row.id)) {
            try store.registerFormulaVersion(StoredFormulaVersion(
                id: E.v1Row.id, formula: E.v2, definition: "x", createdAt: E.day(0)
            ))
        }
        #expect(throws: TargetStoreError.duplicateFormula(existingID: E.v2Row.id)) {
            try store.registerFormulaVersion(StoredFormulaVersion(
                id: uid(9_010), formula: E.v2, definition: "other text", createdAt: E.day(1)
            ))
        }
        #expect(try store.rowCount(FormulaVersion.self) == 2)
    }

    @Test("a row without parameters or with an unknown origin refuses to load")
    func damagedRows() throws {
        let store = try makeInMemoryStore()
        store.context.insert(FormulaVersion(
            id: uid(1), name: "No params", definition: "intake_mean", createdAt: E.day(0),
            originKind: "userEdited", builtinID: nil, paramsJSON: nil
        ))
        try store.context.save()
        #expect(throws: TargetStoreError.invalidFormulaParameters(uid(1))) { try store.formulaVersions() }

        let other = try makeInMemoryStore()
        other.context.insert(FormulaVersion(
            id: uid(2), name: "Odd origin", definition: "intake_mean", createdAt: E.day(0),
            originKind: "fromTheFuture", builtinID: nil,
            paramsJSON: Data(#"{"energyDensityKcalPerKg":7700}"#.utf8)
        ))
        try other.context.save()
        #expect(throws: TargetStoreError.invalidFormulaOrigin(uid(2))) { try other.formulaVersion(id: uid(2)) }

        let zeroRho = try makeInMemoryStore()
        zeroRho.context.insert(FormulaVersion(
            id: uid(3), name: "Zero", definition: "intake_mean", createdAt: E.day(0),
            originKind: "imported", builtinID: nil,
            paramsJSON: Data(#"{"energyDensityKcalPerKg":0}"#.utf8)
        ))
        try zeroRho.context.save()
        #expect(throws: TargetStoreError.invalidFormulaParameters(uid(3))) { try zeroRho.formulaVersions() }
    }
}

@MainActor
@Suite("Target lane: adoption closes and opens stored periods")
struct StoredAdoptionTests {
    @Test("the first adoption opens a period; the next closes it with endDate = yesterday")
    func closeAndOpen() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SwiftDataStore.phone(at: .file(url))
        try store.registerFormulaVersion(E.v1Row)

        let first = try store.adoptTarget(adoption(adopted: 1_800), on: E.noon(21), calendar: E.calendar, id: uid(1))
        #expect(first.period.startDate == E.day(21))
        #expect(first.period.endDate == nil)
        #expect(try store.targetLedger().periods == [first.period])

        // expenditure 2500 → 2500 − 550 = 1950.
        let second = try store.adoptTarget(
            adoption(CalculatedTarget(expenditureKcal: 2_500, rateGoal: E.rate(-0.5))),
            on: E.noon(25), calendar: E.calendar, id: uid(2)
        )
        let ledger = try store.targetLedger()
        #expect(ledger == second.ledger)
        #expect(ledger.periods.count == 2)

        let closed = ledger.periods[0]
        #expect(closed.endDate == E.day(24))
        #expect(closed.id == uid(1))
        #expect(closed.startDate == E.day(21))
        #expect(closed.expenditureAtAdoptionKcal == 2_400)
        #expect(closed.calculatedTargetKcal == 1_850)
        #expect(closed.adoptedTargetKcal == 1_800)
        #expect(closed.proteinTargetG == 128)
        #expect(closed.fatFloorPct == 20)
        #expect(closed.formula == .builtinV1)

        let open = ledger.periods[1]
        #expect(open == ledger.openPeriod)
        #expect(open.startDate == E.day(25))
        #expect(open.expenditureAtAdoptionKcal == 2_500)
        #expect(open.calculatedTargetKcal == 1_950)
        #expect(open.adoptedTargetKcal == 1_950)

        #expect(ledger.period(governing: E.noon(24), calendar: E.calendar)?.id == uid(1))
        #expect(ledger.period(governing: E.noon(25), calendar: E.calendar)?.id == uid(2))
        #expect(ledger.period(governing: E.noon(20), calendar: E.calendar) == nil)

        let reopened = try SwiftDataStore.phone(at: .file(url))
        #expect(try reopened.targetLedger() == ledger)
    }

    @Test("same-day re-adoption keeps the earlier record, governing no day, ahead of the new open period")
    func sameDayReadoption() throws {
        let url = try temporaryStoreURL()
        defer { removeStore(at: url) }
        let store = try SwiftDataStore.phone(at: .file(url))
        try store.registerFormulaVersion(E.v1Row)
        try store.adoptTarget(adoption(), on: E.morning(25), calendar: E.calendar, id: uid(2))
        try store.adoptTarget(adoption(adopted: 1_700), on: E.noon(25), calendar: E.calendar, id: uid(1))

        // uid(1) sorts before uid(2) by id, so order here comes from the
        // closed-before-open rule, not from ids.
        let ledger = try SwiftDataStore.phone(at: .file(url)).targetLedger()
        #expect(ledger.periods.map(\.id) == [uid(2), uid(1)])
        #expect(ledger.periods[0].startDate == E.day(25))
        #expect(ledger.periods[0].endDate == E.day(24))
        #expect(ledger.periods[1].endDate == nil)
        #expect(ledger.period(governing: E.noon(25), calendar: E.calendar)?.id == uid(1))
        #expect(ledger.openPeriod?.adoptedTargetKcal == 1_700)
    }

    @Test("rail warnings come back and the period is still saved")
    func warningsStillSave() throws {
        let store = try storeWithFormulas()
        // 1650 − 550 = 1100 < 1200 warns on the floor; −1.5 kg/wk (> 1.0)
        // warns on the rate, and adjusting that one to 1100 adds the floor.
        let steep = CalculatedTarget(expenditureKcal: 2_925, rateGoal: E.rate(-1.5))
        #expect(steep.kcalPerDay == 1_275) // 2925 − 1650
        let low = CalculatedTarget(expenditureKcal: 1_650, rateGoal: E.rate(-0.5))
        let outcome = try store.adoptTarget(adoption(low), on: E.noon(21), calendar: E.calendar, id: uid(1))
        #expect(outcome.warnings == [.targetBelowFloor])
        let both = try store.adoptTarget(
            adoption(steep, adopted: 1_100), on: E.noon(22), calendar: E.calendar, id: uid(2)
        )
        #expect(both.warnings == [.targetBelowFloor, .rateAboveLimit])
        #expect(try store.targetLedger().periods.map(\.adoptedTargetKcal) == [1_100, 1_100])
    }

    @Test("refused adoptions leave every stored row as it was")
    func refusals() throws {
        let store = try makeInMemoryStore()
        // Not registered yet.
        #expect(throws: TargetStoreError.formulaNotRegistered(name: "FL-EB v1")) {
            try store.adoptTarget(adoption(), on: E.noon(21), calendar: E.calendar, id: uid(1))
        }
        #expect(try store.rowCount(TargetPeriod.self) == 0)

        try store.registerFormulaVersion(E.v1Row)
        try store.registerFormulaVersion(E.v2Row)
        try store.adoptTarget(adoption(), on: E.noon(25), calendar: E.calendar, id: uid(1))
        let before = try E.bytes(store.targetLedger())

        // ρ 7700 target pinned to the ρ 7000 version.
        #expect(throws: TargetStoreError.adoption(.formulaMismatch(calculatedKcalPerKg: 7_700, formulaKcalPerKg: 7_000))) {
            try store.adoptTarget(adoption(formula: E.v2), on: E.noon(26), calendar: E.calendar, id: uid(2))
        }
        #expect(throws: TargetStoreError.adoption(.precedesOpenPeriod(openPeriodStart: E.day(25)))) {
            try store.adoptTarget(adoption(), on: E.noon(24), calendar: E.calendar, id: uid(2))
        }
        #expect(throws: TargetStoreError.adoption(.invalidAdoptedTarget)) {
            try store.adoptTarget(adoption(adopted: 0), on: E.noon(26), calendar: E.calendar, id: uid(2))
        }
        #expect(throws: FreeLunchStoreError.duplicateID(uid(1))) {
            try store.adoptTarget(adoption(), on: E.noon(26), calendar: E.calendar, id: uid(1))
        }
        #expect(try E.bytes(store.targetLedger()) == before)
        #expect(try store.rowCount(TargetPeriod.self) == 1)
    }
}

@MainActor
@Suite("Target lane: stored periods are validated on load")
struct TargetPeriodLoadValidationTests {
    private func insertPeriod(
        _ store: SwiftDataStore,
        id: UUID,
        start: Int,
        end: Int?,
        adopted: Double = 1_900,
        protein: Double = 128,
        formula: FormulaVersion?
    ) {
        store.context.insert(TargetPeriod(
            id: id, startDate: E.day(start), endDate: end.map(E.day),
            expenditureAtAdoptionKcal: 2_450, calculatedTargetKcal: 1_900, adoptedTargetKcal: adopted,
            proteinTargetG: protein, fatFloorPct: 20, formulaVersion: formula
        ))
    }

    private func v1Row(_ store: SwiftDataStore) throws -> FormulaVersion {
        try store.registerFormulaVersion(E.v1Row)
        return try #require(try store.context.fetch(FetchDescriptor<FormulaVersion>()).first)
    }

    @Test("two open periods are refused")
    func twoOpen() throws {
        let store = try makeInMemoryStore()
        let v1 = try v1Row(store)
        insertPeriod(store, id: uid(1), start: 21, end: nil, formula: v1)
        insertPeriod(store, id: uid(2), start: 25, end: nil, formula: v1)
        try store.context.save()
        #expect(throws: TargetStoreError.invalidTargetPeriod(uid(1))) { try store.targetLedger() }
        // Adoption reads the ledger first, so it refuses too.
        #expect(throws: TargetStoreError.invalidTargetPeriod(uid(1))) {
            try store.adoptTarget(adoption(), on: E.noon(30), calendar: E.calendar, id: uid(3))
        }
    }

    @Test("overlapping periods are refused")
    func overlap() throws {
        let store = try makeInMemoryStore()
        let v1 = try v1Row(store)
        insertPeriod(store, id: uid(1), start: 21, end: 26, formula: v1)
        insertPeriod(store, id: uid(2), start: 25, end: nil, formula: v1)
        try store.context.save()
        #expect(throws: TargetStoreError.invalidTargetPeriod(uid(2))) { try store.targetLedger() }
    }

    @Test("a period without its pinned version, or with invalid values, is refused", arguments: [1, 2, 3])
    func damagedValues(variant: Int) throws {
        let store = try makeInMemoryStore()
        let v1 = try v1Row(store)
        switch variant {
        case 1: insertPeriod(store, id: uid(1), start: 21, end: nil, formula: nil)
        case 2: insertPeriod(store, id: uid(1), start: 21, end: nil, adopted: -5, formula: v1)
        default: insertPeriod(store, id: uid(1), start: 21, end: nil, protein: -1, formula: v1)
        }
        try store.context.save()
        #expect(throws: TargetStoreError.invalidTargetPeriod(uid(1))) { try store.targetLedger() }
    }
}
