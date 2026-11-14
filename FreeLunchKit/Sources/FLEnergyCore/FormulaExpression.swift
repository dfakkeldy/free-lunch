// SPDX-License-Identifier: GPL-3.0-or-later

/// A parsed §4 formula. Produced only by ``FormulaParser/parse(_:)``; the
/// parser never evaluates or simplifies anything, so the tree mirrors the
/// text (`1 + 2` stays an addition of two literals).
///
/// The tree carries no source ranges, so two formulas that differ only in
/// spacing or redundant parentheses compare equal. Ranges exist only on
/// ``FormulaDiagnostic``.
public indirect enum FormulaExpression: Sendable, Hashable {
    /// A literal. Always finite: the parser rejects a literal that rounds to
    /// infinity.
    case number(Double)
    case variable(FormulaVariable)
    /// Unary minus, as in `-trend_delta` or `2 * -1`.
    case negate(FormulaExpression)
    case binary(FormulaBinaryOperator, FormulaExpression, FormulaExpression)
    /// A function call. From the parser, `arguments.count` always equals
    /// `function.arity`.
    case call(FormulaFunction, [FormulaExpression])
}

/// The eight names a formula may read. The engine precomputes each value
/// over the version's window; a formula never sees raw series. Names are
/// case-sensitive and the raw value is the spelling in formula text.
public enum FormulaVariable: String, Sendable, Hashable, CaseIterable {
    /// Mean intake over intake-complete days, kcal/day.
    case intakeMean = "intake_mean"
    /// Trend-weight change over the window, kg.
    case trendDelta = "trend_delta"
    /// Trend weight at the end of the window, kg.
    case trendNow = "trend_now"
    /// Trend weight at the start of the window, kg.
    case trendStart = "trend_start"
    /// Length of the window, days.
    case windowDays = "window_days"
    /// Intake-complete days in the window.
    case completeDays = "n_complete"
    /// Weigh-ins in the window.
    case weighInCount = "weigh_in_count"
    /// Energy density, kcal/kg (a per-version parameter).
    case rho = "rho"
}

/// The four functions. Nothing else is callable.
public enum FormulaFunction: String, Sendable, Hashable, CaseIterable {
    /// `min(a, b)`
    case min
    /// `max(a, b)`
    case max
    /// `clamp(x, lo, hi)`
    case clamp
    /// `abs(x)`
    case abs

    /// The exact number of arguments the function takes.
    public var arity: Int {
        switch self {
        case .min, .max: 2
        case .clamp: 3
        case .abs: 1
        }
    }
}

public enum FormulaBinaryOperator: String, Sendable, Hashable, CaseIterable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
}
