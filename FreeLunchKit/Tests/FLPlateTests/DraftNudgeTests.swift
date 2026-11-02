// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import FLPlate
import Foundation
import Testing

@Suite("Draft nudge")
struct DraftNudgeTests {
    private let createdAt = Date(timeIntervalSince1970: 1_767_600_000)

    @Test("staleness begins strictly after twenty-four hours")
    func thresholdIsStrict() {
        let draft = meal(id: 1, state: .draft, createdAt: createdAt)
        #expect(DraftNudge.threshold == 86_400)
        #expect(!DraftNudge.isStale(draft, now: createdAt.addingTimeInterval(86_400)))
        #expect(DraftNudge.isStale(draft, now: createdAt.addingTimeInterval(86_401)))
        #expect(!DraftNudge.isStale(draft, now: createdAt.addingTimeInterval(3_600)))
        let logged = meal(id: 2, state: .logged, createdAt: createdAt.addingTimeInterval(-172_800))
        #expect(!DraftNudge.isStale(logged, now: createdAt))
    }

    @Test("stale drafts filter and order by creation time then identifier")
    func staleDraftOrdering() {
        let earlyB = meal(id: 4, state: .draft, createdAt: createdAt.addingTimeInterval(-172_800))
        let earlyA = meal(id: 3, state: .draft, createdAt: createdAt.addingTimeInterval(-172_800))
        let stale = meal(id: 5, state: .draft, createdAt: createdAt.addingTimeInterval(-86_401))
        let fresh = meal(id: 6, state: .draft, createdAt: createdAt.addingTimeInterval(-86_400))
        let logged = meal(id: 7, state: .logged, createdAt: createdAt.addingTimeInterval(-172_800))
        #expect(DraftNudge.staleDrafts(in: [fresh, earlyB, logged, stale, earlyA], now: createdAt).map(\.id) == [earlyA.id, earlyB.id, stale.id])
    }

    private func meal(id: UInt8, state: MealState, createdAt: Date) -> MealEntryData {
        let identifier = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, id))
        return MealEntryData(
            id: identifier,
            state: state,
            createdAt: createdAt,
            loggedAt: state == .logged ? createdAt : nil,
            source: .phone
        )
    }
}
