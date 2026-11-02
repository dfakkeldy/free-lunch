// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore

/// The way a weigh-as-you-go session interprets scale readings.
public enum ScaleSessionMode: Sendable, Hashable {
    case tared
    case cumulative
}

/// A reading that cannot be accepted into a scale session.
public enum ScaleSessionError: Error, Equatable, Sendable {
    case notFinite(Double)
    case negativeReading(Double)
    case negativeDelta(reading: Double, previous: Double)
}

/// Pure value logic for recording ingredients from a kitchen scale. (spec §2)
public struct ScaleSession: Sendable, Equatable {
    public let mode: ScaleSessionMode
    public private(set) var items: [Grams]
    public private(set) var lastCumulativeReading: Double

    public init(mode: ScaleSessionMode) {
        self.mode = mode
        items = []
        lastCumulativeReading = 0
    }

    /// Returns the grams represented by a reading without changing the session.
    public func grams(forReading reading: Double) throws(ScaleSessionError) -> Grams {
        guard reading.isFinite else {
            throw .notFinite(reading)
        }
        guard reading >= 0 else {
            throw .negativeReading(reading)
        }

        switch mode {
        case .tared:
            return Grams(reading)
        case .cumulative:
            guard reading >= lastCumulativeReading else {
                throw .negativeDelta(reading: reading, previous: lastCumulativeReading)
            }
            return Grams(reading - lastCumulativeReading)
        }
    }

    /// Accepts a reading and appends its per-item grams. Rejected readings leave
    /// both the item list and cumulative baseline unchanged.
    @discardableResult
    public mutating func record(reading: Double) throws(ScaleSessionError) -> Grams {
        let grams = try grams(forReading: reading)
        items.append(grams)
        if mode == .cumulative {
            lastCumulativeReading = reading
        }
        return grams
    }
}
