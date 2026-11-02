// SPDX-License-Identifier: GPL-3.0-or-later
// GLP-1 lane models (spec §1 ShotEvent, MedicationProfile, SideEffectEntry).
//
// Dose-strength periods are derived at query time and never stored.
// Optional enums and enums with a payload are stored as raw strings
// (`siteRaw`, `typeKind` + `otherText`) and mapped in Store/ModelMapping.swift.
import FLCore
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class ShotEvent {
        @Attribute(.unique) var id: UUID
        /// Actual injection time.
        var takenAt: Date
        /// Canonical milligrams.
        var doseMg: Double
        var medication: MedicationProfile?
        var siteRaw: String?
        var note: String?
        var source: ShotSource

        init(
            id: UUID,
            takenAt: Date,
            doseMg: Double,
            medication: MedicationProfile?,
            siteRaw: String?,
            note: String?,
            source: ShotSource
        ) {
            self.id = id
            self.takenAt = takenAt
            self.doseMg = doseMg
            self.medication = medication
            self.siteRaw = siteRaw
            self.note = note
            self.source = source
        }
    }

    @Model
    final class MedicationProfile {
        @Attribute(.unique) var id: UUID
        var name: String
        var halfLifeHours: Double
        var tmaxHours: Double
        var intervalDays: Int
        var archivedAt: Date?
        @Relationship(deleteRule: .deny, inverse: \ShotEvent.medication)
        var shots: [ShotEvent] = []

        init(
            id: UUID,
            name: String,
            halfLifeHours: Double,
            tmaxHours: Double,
            intervalDays: Int,
            archivedAt: Date?
        ) {
            self.id = id
            self.name = name
            self.halfLifeHours = halfLifeHours
            self.tmaxHours = tmaxHours
            self.intervalDays = intervalDays
            self.archivedAt = archivedAt
        }
    }

    @Model
    final class SideEffectEntry {
        @Attribute(.unique) var id: UUID
        var occurredAt: Date
        /// SideEffectType case name; `otherText` carries `.other`'s text.
        var typeKind: String
        var otherText: String?
        var severity: Int
        var note: String?

        init(
            id: UUID,
            occurredAt: Date,
            typeKind: String,
            otherText: String?,
            severity: Int,
            note: String?
        ) {
            self.id = id
            self.occurredAt = occurredAt
            self.typeKind = typeKind
            self.otherText = otherText
            self.severity = severity
            self.note = note
        }
    }
}
