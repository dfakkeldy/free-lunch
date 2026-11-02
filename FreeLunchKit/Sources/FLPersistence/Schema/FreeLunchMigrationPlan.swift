// SPDX-License-Identifier: GPL-3.0-or-later
// FreeLunchMigrationPlan — the day-one, deliberately empty migration ladder
// (spec §1 acceptance #6). Every container is built through it, so stores
// created before v2 exists were already opened under a plan.
//
// When v2 arrives:
//   schemas → [FreeLunchSchemaV1.self, FreeLunchSchemaV2.self]
//   stages  → [migrateV1toV2]        // .lightweight or .custom
// Never reorder or remove an entry; the ladder is append-only.
import Foundation
import SwiftData

enum FreeLunchMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FreeLunchSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
