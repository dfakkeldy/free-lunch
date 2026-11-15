// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Time and portion rules for a watch quick log, independent of storage.
public enum WatchQuickLogRules {
    public static let coalescingInterval: TimeInterval = 10 * 60
    public static let undoInterval: TimeInterval = 5

    public static func coalesces(lastTapAt: Date, tapAt: Date) -> Bool {
        let elapsed = tapAt.timeIntervalSince(lastTapAt)
        return elapsed >= 0 && elapsed <= coalescingInterval
    }

    public static func canUndo(tapAt: Date, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(tapAt)
        return elapsed >= 0 && elapsed < undoInterval
    }

    /// Each crown step is ten percent of the original portion.
    public static func portion(lastPortionGrams: Double, steps: Int) -> Double? {
        guard lastPortionGrams.isFinite, lastPortionGrams > 0 else { return nil }
        let result = lastPortionGrams * (1 + Double(steps) * 0.1)
        return result.isFinite && result > 0 ? result : nil
    }
}
