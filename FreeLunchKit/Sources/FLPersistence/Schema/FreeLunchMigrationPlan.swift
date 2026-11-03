// SPDX-License-Identifier: GPL-3.0-or-later
// FreeLunchMigrationPlan — the migration ladder (spec §1 acceptance #6).
// Every container is built through it, so stores created before a version
// existed were already opened under a plan.
//
// Adding a version:
//   schemas → append FreeLunchSchemaVn.self
//   stages  → append migrateVn-1toVn       // .lightweight or .custom
// Never reorder or remove an entry; the ladder is append-only.
import Foundation
import SwiftData

enum FreeLunchMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FreeLunchSchemaV1.self, FreeLunchSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// V1 → V2 adds three entities (DietarySampleMirror, EnergySettingsRecord,
    /// DidNotTrackMark) and changes nothing else: every V1 entity keeps its
    /// attributes, relationships and unique constraints. That is a change
    /// Core Data's inferred mapping handles on its own (existing rows copied
    /// as they are, empty new tables), so the stage is lightweight. A custom
    /// stage would only add willMigrate / didMigrate closures with no work to
    /// do. Pick custom for a later stage that has to transform or backfill
    /// rows.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: FreeLunchSchemaV1.self,
        toVersion: FreeLunchSchemaV2.self
    )
}
