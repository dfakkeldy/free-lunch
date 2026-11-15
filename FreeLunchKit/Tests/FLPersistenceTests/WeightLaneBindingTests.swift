// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import FLEnergyCore
import Foundation
import Testing
@testable import FLPersistence

@MainActor
@Suite("Weight lane binding")
struct WeightLaneBindingTests {
    typealias E = EnergyStoreFixture

    @Test func sharedTrendAndExclusion() throws {
        let store = try makeInMemoryStore()
        for day in 0...12 {
            try store.upsertWeightSample(WeightSampleData(hkUUID: uid(1000 + day), measuredAt: E.morning(day), weight: Kilograms(80 + Double(day)), sourceBundleID: day.isMultiple(of: 2) ? "synthetic.a" : "synthetic.b"))
        }
        let coordinator = EnergyRecomputeCoordinator(store: store, calendar: E.calendar, ownSourceBundleID: "synthetic", today: E.noon(12), historyFrom: E.day(0))
        let lane = try WeightLaneBinding.series(store: store)
        let engine = try coordinator.refresh()
        #expect(lane.series == engine.key.weights)
        let shared = try EnergyBinding.trendSeries(store: store, smoothing: store.energySettings().smoothing)
        #expect(lane.series == shared)
        let original = try #require(try store.weightSample(hkUUID: uid(1012)))
        let before = lane.stats(now: E.noon(12), visibleRange: E.day(6)...E.noon(12))
        try store.addCorrection(CorrectionData(createdAt: E.noon(12), targetKind: .hkWeightSample, targetID: original.hkUUID.uuidString, action: .exclude))
        let corrected = try WeightLaneBinding.series(store: store)
        #expect(!corrected.points.contains { $0.measuredAt == original.measuredAt })
        #expect(!corrected.segments.joined().contains { $0.measuredAt == original.measuredAt })
        let correctedStats = corrected.stats(now: E.noon(12), visibleRange: E.day(6)...E.noon(12))
        #expect(correctedStats.current != before.current)
        #expect(correctedStats.current == corrected.series.trend(asOf: E.noon(12)))
        #expect(try store.weightSample(hkUUID: original.hkUUID) == original)
        #expect(try store.weightSample(hkUUID: original.hkUUID)?.deletedInHK == false)
        #expect(try coordinator.refresh().key.weights == corrected.series)
    }

    @Test func alphaCascadeChangesWarning() throws {
        let store = try makeInMemoryStore()
        try E.logMeals(store)
        for day in -22...40 {
            let kg = day < 10 ? 80.0 : 85.0
            try store.upsertWeightSample(WeightSampleData(hkUUID: uid(3000 + day + 22), measuredAt: E.morning(day), weight: Kilograms(kg), sourceBundleID: "synthetic"))
        }
        let coordinator = EnergyRecomputeCoordinator(store: store, calendar: E.calendar, ownSourceBundleID: "synthetic", today: E.noon(25), historyFrom: E.day(21))
        let low = try coordinator.setTrendAlpha(0.05)
        let high = try coordinator.setTrendAlpha(0.25)
        let lowTarget = try #require(low.calculatedTarget)
        let highTarget = try #require(high.calculatedTarget)
        #expect(lowTarget.kcalPerDay != highTarget.kcalPerDay)
        // Place the warning threshold strictly between the two synthetic targets.
        let midpoint = (lowTarget.kcalPerDay + highTarget.kcalPerDay) / 2
        _ = try coordinator.setRateGoal(kgPerWeek: lowTarget.rateGoal.kgPerWeek + (TargetRails.minimumTargetKcal - midpoint) * 7 / lowTarget.energyDensityKcalPerKg)
        let first = try coordinator.setTrendAlpha(0.05)
        let second = try coordinator.setTrendAlpha(0.25)
        #expect(first.evaluation.state == second.evaluation.state)
        #expect(try #require(first.calculatedTarget).warnings.contains(.targetBelowFloor) != #require(second.calculatedTarget).warnings.contains(.targetBelowFloor))
        #expect(try WeightLaneBinding.series(store: store).series == second.key.weights)
    }
}
