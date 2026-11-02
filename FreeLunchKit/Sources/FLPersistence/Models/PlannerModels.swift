// SPDX-License-Identifier: GPL-3.0-or-later
// Planner and journal models (spec §1 PlannedShot / PlannedMeal,
// JournalEntry). Planner mechanics are spec §8.
import FLCore
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class PlannedShot {
        @Attribute(.unique) var id: UUID
        var plannedAt: Date
        var notificationID: String?
        var status: PlanStatus
        var fulfilledBy: UUID?
        /// Canonical milligrams.
        var doseMg: Double?

        init(
            id: UUID,
            plannedAt: Date,
            notificationID: String?,
            status: PlanStatus,
            fulfilledBy: UUID?,
            doseMg: Double?
        ) {
            self.id = id
            self.plannedAt = plannedAt
            self.notificationID = notificationID
            self.status = status
            self.fulfilledBy = fulfilledBy
            self.doseMg = doseMg
        }
    }

    @Model
    final class PlannedMeal {
        @Attribute(.unique) var id: UUID
        var plannedAt: Date
        var notificationID: String?
        var status: PlanStatus
        var fulfilledBy: UUID?
        var name: String
        var note: String?

        init(
            id: UUID,
            plannedAt: Date,
            notificationID: String?,
            status: PlanStatus,
            fulfilledBy: UUID?,
            name: String,
            note: String?
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

    @Model
    final class JournalEntry {
        @Attribute(.unique) var id: UUID
        var at: Date
        var text: String
        @Relationship(deleteRule: .cascade, inverse: \PhotoAttachment.journalEntry)
        var photos: [PhotoAttachment] = []

        init(id: UUID, at: Date, text: String) {
            self.id = id
            self.at = at
            self.text = text
        }
    }
}
