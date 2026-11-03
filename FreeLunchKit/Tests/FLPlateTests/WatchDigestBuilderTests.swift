// SPDX-License-Identifier: GPL-3.0-or-later
// The watch digest's day summary and assembly (spec §9). Ordering and the
// 200-food cap are pinned against the §2 typeahead fixture in
// TypeaheadTests. Numbers reuse the post-log fixture: target 2000 kcal,
// P 150, C 260, fat floor 40; logged 1000 kcal, P 60, C 120, F 30.
import FLCore
import FLPlate
import Foundation
import Testing

@Suite("Watch digest builder")
struct WatchDigestBuilderTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2027-01-15 08:00:00 UTC.
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("today-remaining is the adopted target minus what was logged, for today only")
    func todayRemaining() {
        let consumed = MacroAmounts(PlateFixture.totals(1_000, 60, 120, 30))
        let summary = WatchDigestBuilder.todayRemaining(
            target: PlateFixture.target,
            consumed: consumed,
            now: now,
            calendar: calendar
        )

        #expect(summary.day == Date(timeIntervalSince1970: 1_799_971_200))
        #expect(summary.consumed == WatchMacroValues(kcal: 1_000, proteinG: 60, carbsG: 120, fatG: 30))
        #expect(summary.target == WatchMacroValues(kcal: 2_000, proteinG: 150, carbsG: 260, fatG: 40))
        #expect(summary.remaining == WatchMacroValues(kcal: 1_000, proteinG: 90, carbsG: 140, fatG: 10))
    }

    @Test("with no adopted target the summary says so and imputes nothing")
    func noTarget() {
        let summary = WatchDigestBuilder.todayRemaining(
            target: nil,
            consumed: MacroAmounts(PlateFixture.totals(1_000, 60, 120, 30)),
            now: now,
            calendar: calendar
        )

        #expect(summary.target == nil)
        #expect(summary.remaining == nil)
        #expect(summary.consumed.kcal == 1_000)
    }

    @Test("the digest carries its build time, the ranked foods and the given next dose")
    func assembly() {
        let oats = TypeaheadFood(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Oats",
            useCount: 3,
            lastUsedAt: now,
            lastPortionGrams: 40
        )
        let nextDose = WatchNextDoseData(
            medicationID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            medicationName: "Semaglutide",
            doseMg: 0.5,
            nextDoseAt: now.addingTimeInterval(2 * 86_400)
        )

        let digest = WatchDigestBuilder.digest(
            foods: [oats],
            nextDose: nextDose,
            target: nil,
            consumedToday: .zero,
            now: now,
            calendar: calendar
        )

        #expect(digest.generatedAt == now)
        #expect(digest.recentFoods == [RecentFoodSnapshotData(foodID: oats.id, name: "Oats", lastPortionGrams: 40)])
        #expect(digest.nextDose == nextDose)
        #expect(digest.todayRemaining?.target == nil)
    }
}
