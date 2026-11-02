// SPDX-License-Identifier: GPL-3.0-or-later
// Target models (spec §1 TargetPeriod / FormulaVersion; semantics §3/§4).
//
// A TargetPeriod pins its FormulaVersion forever; recalculation never
// rewrites a period. FormulaOrigin's payload is stored as `originKind` +
// `builtinID`. The store API for these is Store/TargetStore.swift.
import FLCore
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class FormulaVersion {
        @Attribute(.unique) var id: UUID
        var name: String
        /// Constrained expression DSL (spec §4).
        var definition: String
        var createdAt: Date
        /// FormulaOrigin case name; `builtinID` carries `.builtin`'s value.
        var originKind: String
        var builtinID: String?
        /// The version's parameters (ρ today) as JSON. Spec §4 gives every
        /// version its own params and spec §3 pins the whole version, so they
        /// live on the row; nil only on rows written before this column.
        var paramsJSON: Data?
        @Relationship(deleteRule: .deny, inverse: \TargetPeriod.formulaVersion)
        var periods: [TargetPeriod] = []

        init(
            id: UUID,
            name: String,
            definition: String,
            createdAt: Date,
            originKind: String,
            builtinID: String?,
            paramsJSON: Data? = nil
        ) {
            self.id = id
            self.name = name
            self.definition = definition
            self.createdAt = createdAt
            self.originKind = originKind
            self.builtinID = builtinID
            self.paramsJSON = paramsJSON
        }
    }

    @Model
    final class TargetPeriod {
        @Attribute(.unique) var id: UUID
        var startDate: Date
        var endDate: Date?
        // The three separate values (spec §1), canonical kcal.
        var expenditureAtAdoptionKcal: Double
        var calculatedTargetKcal: Double
        var adoptedTargetKcal: Double
        var proteinTargetG: Double
        var fatFloorPct: Double
        var formulaVersion: FormulaVersion?

        init(
            id: UUID,
            startDate: Date,
            endDate: Date?,
            expenditureAtAdoptionKcal: Double,
            calculatedTargetKcal: Double,
            adoptedTargetKcal: Double,
            proteinTargetG: Double,
            fatFloorPct: Double,
            formulaVersion: FormulaVersion?
        ) {
            self.id = id
            self.startDate = startDate
            self.endDate = endDate
            self.expenditureAtAdoptionKcal = expenditureAtAdoptionKcal
            self.calculatedTargetKcal = calculatedTargetKcal
            self.adoptedTargetKcal = adoptedTargetKcal
            self.proteinTargetG = proteinTargetG
            self.fatFloorPct = fatFloorPct
            self.formulaVersion = formulaVersion
        }
    }
}
