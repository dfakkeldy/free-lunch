// SPDX-License-Identifier: GPL-3.0-or-later
// Watch-created records waiting for a phone acknowledgement.
import Foundation
import SwiftData

extension FreeLunchSchemaV1 {
    @Model
    final class WatchOutboxRecord {
        @Attribute(.unique) var id: UUID
        /// Stored raw so the persistent schema does not depend on enum coding.
        var kindRaw: String
        var subjectID: UUID
        var queuedAt: Date
        var payload: Data

        init(id: UUID, kind: WatchOutboxKind, subjectID: UUID, queuedAt: Date, payload: Data) {
            self.id = id
            kindRaw = kind.rawValue
            self.subjectID = subjectID
            self.queuedAt = queuedAt
            self.payload = payload
        }

        var kind: WatchOutboxKind? {
            WatchOutboxKind(rawValue: kindRaw)
        }
    }
}
