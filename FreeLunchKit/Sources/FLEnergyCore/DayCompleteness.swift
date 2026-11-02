// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What is known about one calendar day's intake (spec §3 "Day
/// completeness"). The caller decides which calendar day a record belongs
/// to; this type only carries the evidence.
public struct DayIntakeEvidence: Sendable, Hashable {
    /// Logged MealEntries on this day.
    public let loggedMealCount: Int
    /// The day has a reconstructed HealthKit dietary-energy summary
    /// (imports, spec §10). Logged intake counts regardless of how it was
    /// captured.
    public let hasReconstructedDietaryEnergy: Bool
    /// The user marked this day "didn't track" from the timeline.
    public let markedDidNotTrack: Bool

    public init(
        loggedMealCount: Int = 0,
        hasReconstructedDietaryEnergy: Bool = false,
        markedDidNotTrack: Bool = false
    ) {
        self.loggedMealCount = loggedMealCount
        self.hasReconstructedDietaryEnergy = hasReconstructedDietaryEnergy
        self.markedDidNotTrack = markedDidNotTrack
    }
}

/// Explicit intake-completeness state for a calendar day. No guessing.
public enum IntakeCompleteness: Sendable, Hashable {
    case complete
    case incomplete(IntakeIncompleteReason)

    public var isComplete: Bool { self == .complete }
}

public enum IntakeIncompleteReason: Sendable, Hashable {
    /// The user marked the day "didn't track". This wins even when meals
    /// were logged: the mark is the escape valve that keeps a bad day out
    /// of the estimate.
    case markedDidNotTrack
    /// Neither a logged MealEntry nor a reconstructed dietary-energy day.
    case nothingLogged
}

/// Explicit weight-completeness state for a window.
public enum WeightCompleteness: Sendable, Hashable {
    case complete
    case incomplete(WeightIncompleteReason)

    public var isComplete: Bool { self == .complete }
}

public enum WeightIncompleteReason: Sendable, Hashable {
    /// The trend is not yet defined as of the window's end. Reported in
    /// preference to ``tooFewWeighIns`` when both apply.
    case trendUndefined
    /// Fewer than two weigh-ins fall inside the window.
    case tooFewWeighIns
}

public enum DayCompleteness {
    /// A window needs at least this many weigh-ins inside it.
    public static let minimumWeighInsPerWindow = 2

    /// A day is intake-complete iff it has at least one logged MealEntry or
    /// a reconstructed dietary-energy day, and is not marked "didn't track".
    public static func intake(_ evidence: DayIntakeEvidence) -> IntakeCompleteness {
        if evidence.markedDidNotTrack {
            return .incomplete(.markedDidNotTrack)
        }
        if evidence.loggedMealCount >= 1 || evidence.hasReconstructedDietaryEnergy {
            return .complete
        }
        return .incomplete(.nothingLogged)
    }

    /// A window is weight-complete iff the trend is defined as of the
    /// window's end and at least two weigh-ins fall inside the window
    /// (bounds inclusive).
    public static func weight(
        window: ClosedRange<Date>,
        series: TrendSeries
    ) -> WeightCompleteness {
        guard series.isTrendDefined(asOf: window.upperBound) else {
            return .incomplete(.trendUndefined)
        }
        let weighInsInside = series.points.lazy
            .filter { window.contains($0.measuredAt) }
            .count
        guard weighInsInside >= minimumWeighInsPerWindow else {
            return .incomplete(.tooFewWeighIns)
        }
        return .complete
    }
}
