// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — side effects, planner and journal value types (spec §1
// SideEffectEntry, PlannedShot / PlannedMeal, JournalEntry).
import Foundation

/// An on-demand side-effect log (spec §1). Never prompted.
public struct SideEffectEntryData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var occurredAt: Date
    public var type: SideEffectType
    /// `DomainScale.sideEffectSeverity`.
    public var severity: Int
    public var note: String?

    public init(id: UUID = UUID(), occurredAt: Date, type: SideEffectType, severity: Int, note: String? = nil) {
        self.id = id
        self.occurredAt = occurredAt
        self.type = type
        self.severity = severity
        self.note = note
    }
}

/// A planned injection (spec §1 planner schema; mechanics are §8).
public struct PlannedShotData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var plannedAt: Date
    public var notificationID: String?
    public var status: PlanStatus
    /// The ShotEvent that fulfilled this plan.
    public var fulfilledBy: UUID?
    /// Canonical milligrams, when the plan names a dose.
    public private(set) var doseMg: Double?

    public init(
        id: UUID = UUID(),
        plannedAt: Date,
        notificationID: String? = nil,
        status: PlanStatus = .pending,
        fulfilledBy: UUID? = nil,
        dose: Milligrams? = nil
    ) {
        self.id = id
        self.plannedAt = plannedAt
        self.notificationID = notificationID
        self.status = status
        self.fulfilledBy = fulfilledBy
        self.doseMg = dose?.value
    }

    public mutating func setDose(_ dose: Milligrams?) {
        doseMg = dose?.value
    }
}

/// A planned meal (spec §1 planner schema; mechanics are §8).
public struct PlannedMealData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var plannedAt: Date
    public var notificationID: String?
    public var status: PlanStatus
    /// The MealEntry that fulfilled this plan.
    public var fulfilledBy: UUID?
    public var name: String
    public var note: String?

    public init(
        id: UUID = UUID(),
        plannedAt: Date,
        notificationID: String? = nil,
        status: PlanStatus = .pending,
        fulfilledBy: UUID? = nil,
        name: String,
        note: String? = nil
    ) {
        self.id = id
        self.plannedAt = plannedAt
        self.notificationID = notificationID
        self.status = status
        self.fulfilledBy = fulfilledBy
        self.name = name
        self.note = note
    }
}

/// A timeline note or photo that is not a meal (spec §1 JournalEntry).
public struct JournalEntryData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var at: Date
    public var text: String
    /// In display order.
    public var photos: [PhotoAttachmentData]

    public init(id: UUID = UUID(), at: Date, text: String, photos: [PhotoAttachmentData] = []) {
        self.id = id
        self.at = at
        self.text = text
        self.photos = photos
    }
}
