// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The chart and statistics derived from the engine's trend series.
public struct WeightLaneSeries: Sendable, Hashable {
    public let series: TrendSeries
    public var points: [TrendPoint] { series.points }

    public init(series: TrendSeries) { self.series = series }

    /// Defined trend points, split at undefined points and gaps over seven elapsed days.
    public var segments: [[TrendPoint]] {
        var result: [[TrendPoint]] = []
        var run: [TrendPoint] = []
        for point in points {
            guard point.trendKg != nil else {
                if !run.isEmpty { result.append(run); run = [] }
                continue
            }
            if let last = run.last, point.measuredAt.timeIntervalSince(last.measuredAt) > 7 * 86_400 {
                result.append(run)
                run = []
            }
            run.append(point)
        }
        if !run.isEmpty { result.append(run) }
        return result
    }

    /// Trend values and changes in kilograms.
    public struct Stats: Sendable, Hashable {
        public let current: Double?
        public let delta7Days: Double?
        public let delta30Days: Double?
        public let deltaVisibleRange: Double?
    }

    public func stats(now: Date, visibleRange: ClosedRange<Date>) -> Stats {
        func delta(end: Date, start: Date) -> Double? {
            guard let a = series.trend(asOf: end), let b = series.trend(asOf: start) else { return nil }
            return a - b
        }
        return Stats(current: series.trend(asOf: now),
                     delta7Days: delta(end: now, start: now.addingTimeInterval(-7 * 86_400)),
                     delta30Days: delta(end: now, start: now.addingTimeInterval(-30 * 86_400)),
                     deltaVisibleRange: delta(end: visibleRange.upperBound, start: visibleRange.lowerBound))
    }
}

/// Preset chart windows. Calendar arithmetic keeps month and year boundaries meaningful.
public enum WeightLaneRange: Sendable, Hashable, CaseIterable {
    case oneMonth, threeMonths, sixMonths, oneYear, all

    public func bounds(endingAt end: Date, firstSample: Date?, calendar: Calendar) -> ClosedRange<Date> {
        let start: Date
        switch self {
        case .oneMonth: start = calendar.date(byAdding: .month, value: -1, to: end)!
        case .threeMonths: start = calendar.date(byAdding: .month, value: -3, to: end)!
        case .sixMonths: start = calendar.date(byAdding: .month, value: -6, to: end)!
        case .oneYear: start = calendar.date(byAdding: .year, value: -1, to: end)!
        case .all: start = min(firstSample ?? end, end)
        }
        return start...end
    }
}
