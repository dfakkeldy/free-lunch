// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — MedicationProfileData (spec §1 MedicationProfile)
//
// Value-type mirror of the MedicationProfile entity. The `Data` suffix keeps
// the name free for the SwiftData model in FLPersistence. Pharmacokinetic
// parameters are plain hours; the exposure curve that reads them is spec §5.
import Foundation

/// Medications with prefilled pharmacokinetic parameters (spec §1). Every
/// value stays editable on the profile, and custom profiles are allowed.
public enum KnownMedication: String, Sendable, Hashable, Codable, CaseIterable {
    case semaglutide
    case tirzepatide
    case liraglutide

    public var displayName: String {
        switch self {
        case .semaglutide: "Semaglutide"
        case .tirzepatide: "Tirzepatide"
        case .liraglutide: "Liraglutide"
        }
    }

    /// Elimination half-life prefill, hours.
    public var halfLifeHours: Double {
        switch self {
        case .semaglutide: 168
        case .tirzepatide: 120
        case .liraglutide: 13
        }
    }

    /// Absorption peak prefill, hours.
    public var tmaxHours: Double {
        switch self {
        case .semaglutide: 36
        case .tirzepatide: 24
        case .liraglutide: 11
        }
    }
}

public struct MedicationProfileData: Sendable, Hashable, Codable, Identifiable {
    /// Spec §1 default dosing interval.
    public static let defaultIntervalDays = 7

    public let id: UUID
    public var name: String
    public var halfLifeHours: Double
    public var tmaxHours: Double
    public var intervalDays: Int
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        halfLifeHours: Double,
        tmaxHours: Double,
        intervalDays: Int = MedicationProfileData.defaultIntervalDays,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.halfLifeHours = halfLifeHours
        self.tmaxHours = tmaxHours
        self.intervalDays = intervalDays
        self.archivedAt = archivedAt
    }

    /// A profile prefilled from a known medication. Only the half-life and
    /// tmax are prefilled; the interval takes the spec default unless given.
    public init(
        id: UUID = UUID(),
        known: KnownMedication,
        intervalDays: Int = MedicationProfileData.defaultIntervalDays
    ) {
        self.init(
            id: id,
            name: known.displayName,
            halfLifeHours: known.halfLifeHours,
            tmaxHours: known.tmaxHours,
            intervalDays: intervalDays
        )
    }
}
