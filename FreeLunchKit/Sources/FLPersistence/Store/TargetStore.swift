// SPDX-License-Identifier: GPL-3.0-or-later
// Target lane (spec §1 TargetPeriod / FormulaVersion, semantics spec §3):
// FLEnergyCore's ledger, persisted.
//
// ## Integrity rules carried by the API's shape (spec §3)
//
// - **Adoption is the only write to a TargetPeriod.** It closes the open
//   period (its `endDate`, nothing else) and inserts the new one. There is no
//   method that edits or deletes a period, so no recalculation path can
//   reach one (spec §3 acceptance #4).
// - **Adoption goes through `TargetLedger.adopting`**, so the energy core's
//   rules (endDate = yesterday, same-day re-adoption, ρ must match the pinned
//   version, rail warnings) are the store's rules.
// - **Formula versions are immutable once registered.** There is no update
//   or delete; a change to the math is a new version (spec §3 "Versioning").
//   A period references its version row, so history renders with the math
//   it pinned (spec §3 acceptance #5).
// - **The activation schedule is not stored here.** Spec §1 has no entity
//   for it; like the rate goal, α and the adoption mode it is a setting.
//   `FormulaActivationSchedule` is Codable for whoever holds settings.
//
// Loading validates every row (finite values, a resolvable pinned version,
// at most one open period and no overlap) and refuses a ledger that fails,
// so a damaged store never renders as a plausible history.
import FLCore
import FLEnergyCore
import Foundation
import SwiftData

/// A formula version as stored: the energy core's value plus the row's
/// identity, its expression text (spec §4 DSL) and when it was created.
public struct StoredFormulaVersion: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let formula: EnergyFormulaVersion
    /// The version's expression (spec §4), for display and export.
    public let definition: String
    public let createdAt: Date

    public init(id: UUID, formula: EnergyFormulaVersion, definition: String, createdAt: Date) {
        self.id = id
        self.formula = formula
        self.definition = definition
        self.createdAt = createdAt
    }

    /// The shipped builtin `FL-EB v1`, ready to register.
    public static func builtinV1(id: UUID, createdAt: Date) -> StoredFormulaVersion {
        StoredFormulaVersion(
            id: id,
            formula: .builtinV1,
            definition: EnergyFormulaVersion.builtinV1Definition,
            createdAt: createdAt
        )
    }
}

/// Why a target-lane call was refused. Refusals are decided before any row
/// is touched, so a refused call leaves the store unchanged.
public enum TargetStoreError: Error, Equatable, Sendable {
    /// A version equal to this one (name, origin and parameters) is already
    /// registered under the given id. Versions are looked up by value at
    /// adoption, so two equal rows would make the pin ambiguous.
    case duplicateFormula(existingID: UUID)
    /// The adoption's formula version has not been registered.
    case formulaNotRegistered(name: String)
    /// A stored version's origin is not one this build knows.
    case invalidFormulaOrigin(UUID)
    /// A stored version has no parameters, or they do not decode to a valid
    /// set (ρ finite and positive).
    case invalidFormulaParameters(UUID)
    /// A stored period fails validation: a non-finite or non-positive value,
    /// invalid macros, no pinned version, a second open period, or an
    /// overlap with the period before it.
    case invalidTargetPeriod(UUID)
    /// The energy core refused the adoption.
    case adoption(TargetLedger.AdoptionError)
}

/// Adopted targets and the formula versions they pin.
@MainActor
public protocol TargetStore: AnyObject {
    /// Throws `FreeLunchStoreError.duplicateID` for an id in use and
    /// `duplicateFormula` when an equal version is already registered.
    func registerFormulaVersion(_ version: StoredFormulaVersion) throws
    func formulaVersion(id: UUID) throws -> StoredFormulaVersion?
    /// By `createdAt`, then id.
    func formulaVersions() throws -> [StoredFormulaVersion]

    /// Every stored period, oldest first, validated.
    func targetLedger() throws -> TargetLedger

    /// Explicit adoption on `day` (spec §3 "Adopted target"): closes the open
    /// period with endDate = yesterday and stores a new open period pinning
    /// the adoption's values and its registered formula version. Returns the
    /// energy core's outcome, rail warnings included; warnings never block.
    @discardableResult
    func adoptTarget(_ adoption: TargetAdoption, on day: Date, calendar: Calendar, id: UUID) throws -> AdoptionOutcome
}

extension SwiftDataStore: TargetStore {
    public func registerFormulaVersion(_ version: StoredFormulaVersion) throws {
        try requireStoreKind(.phone, operation: "registerFormulaVersion")
        guard try targetRow(FormulaVersion.self, id: version.id) == nil else {
            throw FreeLunchStoreError.duplicateID(version.id)
        }
        if let existing = try formulaRow(matching: version.formula) {
            throw TargetStoreError.duplicateFormula(existingID: existing.id)
        }
        let origin = FormulaOriginCoding.kind(of: FormulaOrigin(version.formula.origin))
        context.insert(
            FormulaVersion(
                id: version.id,
                name: version.formula.name,
                definition: version.definition,
                createdAt: version.createdAt,
                originKind: origin.kind,
                builtinID: origin.builtinID,
                paramsJSON: try FormulaParamsCoding.encode(version.formula.parameters)
            )
        )
        try commit()
    }

    public func formulaVersion(id: UUID) throws -> StoredFormulaVersion? {
        try requireStoreKind(.phone, operation: "formulaVersion")
        return try targetRow(FormulaVersion.self, id: id)?.asStoredFormulaVersion()
    }

    public func formulaVersions() throws -> [StoredFormulaVersion] {
        try requireStoreKind(.phone, operation: "formulaVersions")
        return try context.fetch(FetchDescriptor<FormulaVersion>())
            .map { try $0.asStoredFormulaVersion() }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func targetLedger() throws -> TargetLedger {
        try requireStoreKind(.phone, operation: "targetLedger")
        return TargetLedger(periods: try storedPeriods().map(\.period))
    }

    @discardableResult
    public func adoptTarget(
        _ adoption: TargetAdoption,
        on day: Date,
        calendar: Calendar,
        id: UUID
    ) throws -> AdoptionOutcome {
        try requireStoreKind(.phone, operation: "adoptTarget")
        let stored = try storedPeriods()
        guard try targetRow(TargetPeriod.self, id: id) == nil else {
            throw FreeLunchStoreError.duplicateID(id)
        }
        guard let formulaRow = try formulaRow(matching: adoption.formula) else {
            throw TargetStoreError.formulaNotRegistered(name: adoption.formula.name)
        }

        let ledger = TargetLedger(periods: stored.map(\.period))
        let outcome: AdoptionOutcome
        do {
            outcome = try ledger.adopting(adoption, on: day, calendar: calendar, id: id)
        } catch {
            throw TargetStoreError.adoption(error)
        }

        // The energy core closed the open period, if any: copy its end date,
        // and only its end date, onto that row.
        if let open = ledger.openPeriod, let openRow = stored.last?.row {
            let closed = outcome.ledger.periods[outcome.ledger.periods.count - 2]
            precondition(closed.id == open.id && openRow.id == open.id, "adoption closes the open period")
            openRow.endDate = closed.endDate
        }
        let period = outcome.period
        context.insert(
            TargetPeriod(
                id: period.id,
                startDate: period.startDate,
                endDate: period.endDate,
                expenditureAtAdoptionKcal: period.expenditureAtAdoptionKcal,
                calculatedTargetKcal: period.calculatedTargetKcal,
                adoptedTargetKcal: period.adoptedTargetKcal,
                proteinTargetG: period.proteinTargetG,
                fatFloorPct: period.fatFloorPct,
                formulaVersion: formulaRow
            )
        )
        try commit()
        return outcome
    }

    // MARK: - Helpers

    /// Every period row with its value, oldest first, validated as a ledger.
    ///
    /// Order: start date; on a shared start date, closed periods before the
    /// open one (a same-day re-adoption closes the earlier period with an end
    /// date before its start), then end date, then id. Rows carry no
    /// insertion order, so two same-day re-adoptions closed on the same day
    /// sort by id; neither governs any day.
    private func storedPeriods() throws -> [(row: TargetPeriod, period: AdoptedTargetPeriod)] {
        let rows = try context.fetch(FetchDescriptor<TargetPeriod>())
        let pairs = try rows.map { row in (row: row, period: try row.asAdoptedTargetPeriod()) }
            .sorted { lhs, rhs in
                let l = lhs.period
                let r = rhs.period
                if l.startDate != r.startDate { return l.startDate < r.startDate }
                switch (l.endDate, r.endDate) {
                case (nil, .some): return false
                case (.some, nil): return true
                case let (le?, re?) where le != re: return le < re
                default: return l.id.uuidString < r.id.uuidString
                }
            }
        var previous: AdoptedTargetPeriod?
        for (index, pair) in pairs.enumerated() {
            let period = pair.period
            if period.isOpen, index != pairs.count - 1 {
                throw TargetStoreError.invalidTargetPeriod(period.id)
            }
            // The period before must end before this one starts.
            if let previousEnd = previous?.endDate, previousEnd >= period.startDate {
                throw TargetStoreError.invalidTargetPeriod(period.id)
            }
            previous = period
        }
        return pairs
    }

    /// The registered version equal to `formula`, if any.
    private func formulaRow(matching formula: EnergyFormulaVersion) throws -> FormulaVersion? {
        // Formula value equality includes decoded parameters, which SwiftData
        // cannot predicate directly; the small registered-version list is not
        // a keyed id lookup.
        try context.fetch(FetchDescriptor<FormulaVersion>())
            .first { try $0.asEnergyFormulaVersion() == formula }
    }

    private func targetRow<T: PersistentModel & IdentifiedByUUID>(_ type: T.Type, id: UUID) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: T.predicate(id: id))
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

extension FormulaVersion: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<FormulaVersion> { #Predicate { $0.id == id } }
}

extension TargetPeriod: IdentifiedByUUID {
    static func predicate(id: UUID) -> Predicate<TargetPeriod> { #Predicate { $0.id == id } }
}

// MARK: - Mapping

enum FormulaParamsCoding {
    static func encode(_ parameters: ExpenditureParameters) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(parameters)
    }

    /// Nil for missing or invalid parameters (decoding rejects ρ ≤ 0).
    static func decode(_ data: Data?) -> ExpenditureParameters? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ExpenditureParameters.self, from: data)
    }
}

extension FormulaOrigin {
    init(_ origin: EnergyFormulaOrigin) {
        switch origin {
        case .builtin(let id): self = .builtin(id)
        case .userEdited: self = .userEdited
        case .imported: self = .imported
        }
    }
}

extension EnergyFormulaOrigin {
    init(_ origin: FormulaOrigin) {
        switch origin {
        case .builtin(let id): self = .builtin(id)
        case .userEdited: self = .userEdited
        case .imported: self = .imported
        }
    }
}

extension FormulaVersion {
    func asEnergyFormulaVersion() throws -> EnergyFormulaVersion {
        guard let origin = FormulaOriginCoding.origin(kind: originKind, builtinID: builtinID) else {
            throw TargetStoreError.invalidFormulaOrigin(id)
        }
        guard let parameters = FormulaParamsCoding.decode(paramsJSON) else {
            throw TargetStoreError.invalidFormulaParameters(id)
        }
        return EnergyFormulaVersion(name: name, origin: EnergyFormulaOrigin(origin), parameters: parameters)
    }

    func asStoredFormulaVersion() throws -> StoredFormulaVersion {
        StoredFormulaVersion(id: id, formula: try asEnergyFormulaVersion(), definition: definition, createdAt: createdAt)
    }
}

extension TargetPeriod {
    /// How far before its start a closed period's end date may fall. Only a
    /// same-day re-adoption ends a period before its start, and then by
    /// exactly one calendar day (endDate = yesterday): 23 to 25 hours across
    /// a DST change. 36 hours admits that day in any time zone and rejects a
    /// row that ends two or more days before it starts.
    static let maxEndBeforeStart: TimeInterval = 36 * 3_600

    func asAdoptedTargetPeriod() throws -> AdoptedTargetPeriod {
        guard let formulaVersion,
              expenditureAtAdoptionKcal.isFinite,
              expenditureAtAdoptionKcal > 0,
              calculatedTargetKcal.isFinite,
              calculatedTargetKcal > 0,
              adoptedTargetKcal.isFinite, adoptedTargetKcal > 0,
              MacroTargets(proteinTargetG: proteinTargetG, fatFloorPct: fatFloorPct) != nil,
              endDate.map({ $0 >= startDate.addingTimeInterval(-Self.maxEndBeforeStart) }) ?? true
        else {
            throw TargetStoreError.invalidTargetPeriod(id)
        }
        return AdoptedTargetPeriod(
            id: id,
            startDate: startDate,
            endDate: endDate,
            expenditureAtAdoptionKcal: expenditureAtAdoptionKcal,
            calculatedTargetKcal: calculatedTargetKcal,
            adoptedTargetKcal: adoptedTargetKcal,
            proteinTargetG: proteinTargetG,
            fatFloorPct: fatFloorPct,
            formula: try formulaVersion.asEnergyFormulaVersion()
        )
    }
}
