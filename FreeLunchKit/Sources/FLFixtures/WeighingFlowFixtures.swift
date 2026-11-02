// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic kitchen-scale reading sequences for the weighing flows (spec §2
// "Weighing flows", acceptance #3). The expected grams were worked out by
// hand from the readings, not taken from the implementation.

/// One reading typed during a scale session, and what it should become.
public struct ScaleReadingFixture: Sendable, Hashable {
    /// What the scale shows.
    public let reading: Double
    /// The item's grams, or nil when the reading must be refused and the
    /// user asked to re-enter it.
    public let expectedGrams: Double?

    public init(reading: Double, expectedGrams: Double?) {
        self.reading = reading
        self.expectedGrams = expectedGrams
    }
}

public enum WeighingFlowFixtures {
    /// One bowl, never tared. The fourth reading is below the running total
    /// (a misread), is refused, and does not move the baseline: the next
    /// item is measured from 412.5 g, not from 400 g.
    ///
    ///     250    − 0     = 250
    ///     412.5  − 250   = 162.5
    ///     400    < 412.5   refused
    ///     475    − 412.5 = 62.5
    ///     537.25 − 475   = 62.25
    ///
    /// Every item is a multiple of 0.25 g, so with whole-number per-100 g
    /// values each nutrition snapshot is an exact decimal.
    public static let cumulative: [ScaleReadingFixture] = [
        ScaleReadingFixture(reading: 250, expectedGrams: 250),
        ScaleReadingFixture(reading: 412.5, expectedGrams: 162.5),
        ScaleReadingFixture(reading: 400, expectedGrams: nil),
        ScaleReadingFixture(reading: 475, expectedGrams: 62.5),
        ScaleReadingFixture(reading: 537.25, expectedGrams: 62.25)
    ]

    /// Tared between items: each reading is the item. Out-of-order sizes
    /// are fine; a 0 g reading adds nothing and is refused.
    public static let tared: [ScaleReadingFixture] = [
        ScaleReadingFixture(reading: 45, expectedGrams: 45),
        ScaleReadingFixture(reading: 120.25, expectedGrams: 120.25),
        ScaleReadingFixture(reading: 0, expectedGrams: nil),
        ScaleReadingFixture(reading: 8.5, expectedGrams: 8.5)
    ]
}
