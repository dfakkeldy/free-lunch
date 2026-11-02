// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — ShotEventData (spec §1 ShotEvent)
//
// Value-type mirror of the ShotEvent entity. `takenAt` is the actual
// injection time. The dose is stored in milligrams only and can be set only
// through `Milligrams` or a `Measurement<UnitMass>`, so a microgram or gram
// figure is converted before it is kept. The medication is a UUID reference
// to a MedicationProfile.
import Foundation

public struct ShotEventData: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var takenAt: Date
    /// Canonical milligrams. Change it with `setDose(_:)`.
    public private(set) var doseMg: Double
    public var medicationID: UUID
    public var site: InjectionSite?
    public var note: String?
    public var source: ShotSource

    public init(
        id: UUID = UUID(),
        takenAt: Date,
        dose: Milligrams,
        medicationID: UUID,
        site: InjectionSite? = nil,
        note: String? = nil,
        source: ShotSource = .phone
    ) {
        self.id = id
        self.takenAt = takenAt
        self.doseMg = dose.value
        self.medicationID = medicationID
        self.site = site
        self.note = note
        self.source = source
    }

    /// Accepts any mass unit (µg, mg, g) and stores milligrams.
    public init(
        id: UUID = UUID(),
        takenAt: Date,
        dose: Measurement<UnitMass>,
        medicationID: UUID,
        site: InjectionSite? = nil,
        note: String? = nil,
        source: ShotSource = .phone
    ) throws(CanonicalUnitError) {
        self.init(
            id: id,
            takenAt: takenAt,
            dose: try Milligrams(dose),
            medicationID: medicationID,
            site: site,
            note: note,
            source: source
        )
    }

    public mutating func setDose(_ dose: Milligrams) {
        doseMg = dose.value
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case takenAt
        case doseMg
        case medicationID
        case site
        case note
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        takenAt = try container.decode(Date.self, forKey: .takenAt)
        doseMg = try container.decode(Milligrams.self, forKey: .doseMg).value
        medicationID = try container.decode(UUID.self, forKey: .medicationID)
        site = try container.decodeIfPresent(InjectionSite.self, forKey: .site)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        source = try container.decode(ShotSource.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(takenAt, forKey: .takenAt)
        try container.encode(doseMg, forKey: .doseMg)
        try container.encode(medicationID, forKey: .medicationID)
        try container.encodeIfPresent(site, forKey: .site)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(source, forKey: .source)
    }
}
