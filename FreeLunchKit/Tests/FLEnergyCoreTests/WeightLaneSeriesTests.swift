// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import FLEnergyCore

@Suite("Weight lane series")
struct WeightLaneSeriesTests {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)
    func point(_ seconds: Double, _ trend: Double?) -> TrendPoint {
        TrendPoint(measuredAt: origin.addingTimeInterval(seconds), weightKg: 80, trendKg: trend)
    }
    @Test func gaps() {
        let day = 86_400.0
        let points = [point(0, nil), point(day, 80), point(7 * day, 79), point(14 * day, 78),
                      point(22 * day, 77), point(29 * day + 1, 76)]
        let lane = WeightLaneSeries(series: TrendSeries(smoothing: .standard, points: points))
        #expect(lane.points == points)
        #expect(lane.segments == [Array(points[1...3]), [points[4]], [points[5]]])
    }
    @Test func statsAndRanges() {
        let day = 86_400.0
        let points = [point(0, nil), point(5 * day, 80), point(20 * day, 78), point(40 * day, 75)]
        let lane = WeightLaneSeries(series: TrendSeries(smoothing: .standard, points: points))
        let now = origin.addingTimeInterval(40 * day)
        let stats = lane.stats(now: now, visibleRange: origin.addingTimeInterval(20 * day)...now)
        #expect(stats.current == 75)
        #expect(stats.delta7Days == -3)
        #expect(stats.delta30Days == -5)
        #expect(stats.deltaVisibleRange == -3)
        #expect(lane.stats(now: now, visibleRange: origin...now).deltaVisibleRange == nil)
        #expect(lane.stats(now: origin, visibleRange: origin...now).current == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for (range, component, value) in [(WeightLaneRange.oneMonth, Calendar.Component.month, -1), (.threeMonths, .month, -3), (.sixMonths, .month, -6), (.oneYear, .year, -1)] {
            #expect(range.bounds(endingAt: now, firstSample: origin, calendar: calendar).lowerBound == calendar.date(byAdding: component, value: value, to: now))
        }
        #expect(WeightLaneRange.all.bounds(endingAt: now, firstSample: origin, calendar: calendar) == origin...now)
    }
}
