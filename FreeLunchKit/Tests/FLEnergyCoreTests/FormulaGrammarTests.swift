// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import FLEnergyCore

// Spec §4 acceptance #1: grammar vectors. Expected trees and diagnostic
// ranges are written out by hand from the grammar, not taken from the
// parser's output. Ranges are UTF-16 offsets.

private typealias E = FormulaExpression

private func num(_ value: Double) -> E { .number(value) }
private func v(_ variable: FormulaVariable) -> E { .variable(variable) }
private func add(_ a: E, _ b: E) -> E { .binary(.add, a, b) }
private func sub(_ a: E, _ b: E) -> E { .binary(.subtract, a, b) }
private func mul(_ a: E, _ b: E) -> E { .binary(.multiply, a, b) }
private func div(_ a: E, _ b: E) -> E { .binary(.divide, a, b) }

private func parsed(_ source: String) -> E? {
    try? FormulaParser.parse(source).get()
}

private func diagnostic(_ source: String) -> FormulaDiagnostic? {
    if case .failure(let error) = FormulaParser.parse(source) { return error }
    return nil
}

private func nested(_ open: String, _ levels: Int, around inner: String = "1") -> String {
    String(repeating: open, count: levels) + inner + String(repeating: ")", count: levels)
}

/// The largest finite Double written out in full: 309 digits.
private let largestFiniteLiteral = "179769313486231570" + String(repeating: "0", count: 291)

struct AcceptRow: CustomTestStringConvertible, Sendable {
    let source: String
    let expected: FormulaExpression
    let note: String
    var testDescription: String { note }
}

struct RejectRow: CustomTestStringConvertible, Sendable {
    let source: String
    let kind: FormulaDiagnostic.Kind
    let range: Range<Int>
    let note: String
    var testDescription: String { note }
}

private let acceptRows: [AcceptRow] = [
    AcceptRow(
        source: EnergyFormulaVersion.builtinV1Definition,
        expected: sub(v(.intakeMean), div(mul(v(.trendDelta), v(.rho)), v(.windowDays))),
        note: "the builtin FL-EB v1 text"
    ),
    AcceptRow(source: "min(1, 2)", expected: .call(.min, [num(1), num(2)]), note: "min at arity 2"),
    AcceptRow(source: "max(trend_now,trend_start)", expected: .call(.max, [v(.trendNow), v(.trendStart)]), note: "max at arity 2"),
    AcceptRow(
        source: "clamp(n_complete, 0, 21)",
        expected: .call(.clamp, [v(.completeDayCount), num(0), num(21)]),
        note: "clamp at arity 3"
    ),
    AcceptRow(source: "abs(-weigh_in_count)", expected: .call(.abs, [.negate(v(.weighInCount))]), note: "abs at arity 1"),
    AcceptRow(source: "1 + 2 * 3", expected: add(num(1), mul(num(2), num(3))), note: "* binds tighter than +"),
    AcceptRow(source: "1 - 2 - 3", expected: sub(sub(num(1), num(2)), num(3)), note: "- is left-associative"),
    AcceptRow(source: "8 / 4 / 2", expected: div(div(num(8), num(4)), num(2)), note: "/ is left-associative"),
    AcceptRow(source: "(1 + 2) * 3", expected: mul(add(num(1), num(2)), num(3)), note: "parentheses group"),
    AcceptRow(source: "-2 * 3", expected: mul(.negate(num(2)), num(3)), note: "unary minus binds tighter than *"),
    AcceptRow(source: "2 * -3", expected: mul(num(2), .negate(num(3))), note: "unary minus after an operator"),
    AcceptRow(source: "1 - -rho", expected: sub(num(1), .negate(v(.rho))), note: "binary minus then unary minus"),
    AcceptRow(source: "--1", expected: .negate(.negate(num(1))), note: "repeated unary minus"),
    AcceptRow(source: "-(1 + 2)", expected: .negate(add(num(1), num(2))), note: "unary minus on a group"),
    AcceptRow(source: "0.5 + 007 + 1.25", expected: add(add(num(0.5), num(7)), num(1.25)), note: "literal shapes"),
    AcceptRow(source: largestFiniteLiteral, expected: num(.greatestFiniteMagnitude), note: "largest finite literal"),
    AcceptRow(source: "-0", expected: .negate(num(0)), note: "minus zero is a negated literal"),
    AcceptRow(source: "min (1, 2)", expected: .call(.min, [num(1), num(2)]), note: "space before a call's ("),
    AcceptRow(
        source: Array(repeating: "(1)", count: 17).joined(separator: " + "),
        expected: (1..<17).reduce(num(1)) { sum, _ in add(sum, num(1)) },
        note: "17 sibling groups are depth 1"
    ),
    AcceptRow(source: "((rho))", expected: v(.rho), note: "redundant parentheses leave no trace"),
    AcceptRow(source: "\t1\r\n+\n2 \r", expected: add(num(1), num(2)), note: "tab, CR, LF and CRLF are whitespace"),
    AcceptRow(source: nested("(", 16), expected: num(1), note: "16 nested groups"),
    AcceptRow(
        source: nested("abs(", 16),
        expected: (0..<16).reduce(num(1)) { inner, _ in .call(.abs, [inner]) },
        note: "16 nested calls"
    ),
    AcceptRow(
        source: nested("abs(", 8, around: nested("(", 8)),
        expected: (0..<8).reduce(num(1)) { inner, _ in .call(.abs, [inner]) },
        note: "8 calls around 8 groups is depth 16"
    ),
    AcceptRow(
        source: "min(" + nested("(", 15) + ", 2)",
        expected: .call(.min, [num(1), num(2)]),
        note: "a call plus 15 groups is depth 16"
    ),
    AcceptRow(
        source: "rho" + String(repeating: " ", count: 497),
        expected: v(.rho),
        note: "exactly 500 UTF-16 units"
    ),
]

private let rejectRows: [RejectRow] = [
    // Unknown identifiers.
    RejectRow(source: "Rho", kind: .unknownIdentifier("Rho"), range: 0..<3, note: "names are case-sensitive"),
    RejectRow(source: "foo + 1", kind: .unknownIdentifier("foo"), range: 0..<3, note: "an unknown variable"),
    RejectRow(source: "rho(1)", kind: .unknownIdentifier("rho"), range: 0..<3, note: "a variable called as a function"),
    RejectRow(source: "1 + Min(1, 2)", kind: .unknownIdentifier("Min"), range: 4..<7, note: "function names are case-sensitive"),
    RejectRow(source: "sqrt(4)", kind: .unknownIdentifier("sqrt"), range: 0..<4, note: "only four functions exist"),
    RejectRow(source: "rho (1)", kind: .unknownIdentifier("rho"), range: 0..<3, note: "a spaced variable call"),
    RejectRow(source: "min + 1", kind: .unknownIdentifier("min"), range: 0..<3, note: "a function used as a value"),

    // Arity.
    RejectRow(source: "min(1,2,3)", kind: .wrongArgumentCount(.min, expected: 2, found: 3), range: 0..<10, note: "min with 3"),
    RejectRow(source: "clamp(1)", kind: .wrongArgumentCount(.clamp, expected: 3, found: 1), range: 0..<8, note: "clamp with 1"),
    RejectRow(source: "abs()", kind: .wrongArgumentCount(.abs, expected: 1, found: 0), range: 0..<5, note: "abs with 0"),
    RejectRow(source: "abs( )", kind: .wrongArgumentCount(.abs, expected: 1, found: 0), range: 0..<6, note: "abs with 0, spaced"),
    RejectRow(source: "1 + max(rho)", kind: .wrongArgumentCount(.max, expected: 2, found: 1), range: 4..<12, note: "max with 1"),

    // Caps.
    RejectRow(source: nested("(", 17), kind: .tooDeep, range: 16..<17, note: "17 nested groups"),
    RejectRow(source: nested("abs(", 17), kind: .tooDeep, range: 67..<68, note: "17 nested calls"),
    RejectRow(source: "min(" + nested("(", 16) + ", 2)", kind: .tooDeep, range: 19..<20, note: "a call plus 16 groups"),
    RejectRow(
        source: "1" + String(repeating: " ", count: 500),
        kind: .tooLong(length: 501), range: 500..<501,
        note: "501 UTF-16 units"
    ),
    RejectRow(
        // 500 Characters but 501 UTF-16 units: the cap counts units, and
        // the range covers the whole emoji that crosses it.
        source: "1" + String(repeating: " ", count: 498) + "😀",
        kind: .tooLong(length: 501), range: 499..<501,
        note: "an emoji crossing the cap"
    ),
    RejectRow(
        source: "#" + String(repeating: " ", count: 600),
        kind: .tooLong(length: 601), range: 500..<601,
        note: "length is checked before anything else"
    ),

    // Stray tokens and characters.
    RejectRow(source: "1 2", kind: .unexpectedToken, range: 2..<3, note: "two operands in a row"),
    RejectRow(source: "(1, 2)", kind: .unexpectedToken, range: 2..<3, note: "a comma outside a call"),
    RejectRow(source: "#", kind: .unexpectedCharacter, range: 0..<1, note: "#"),
    RejectRow(source: "😀", kind: .unexpectedCharacter, range: 0..<2, note: "an emoji is 2 units"),
    RejectRow(source: "1 + 😀", kind: .unexpectedCharacter, range: 4..<6, note: "an emoji after a token"),
    RejectRow(source: "👍🏽", kind: .unexpectedCharacter, range: 0..<4, note: "an emoji with a skin-tone modifier"),
    RejectRow(source: "e\u{301}", kind: .unexpectedCharacter, range: 0..<2, note: "a letter with a combining mark"),
    RejectRow(source: "rh\u{F3}", kind: .unexpectedCharacter, range: 2..<3, note: "an accented letter ending a name"),
    RejectRow(source: "rho\u{301}", kind: .unexpectedCharacter, range: 2..<4, note: "a combining mark ending a name"),
    RejectRow(source: "21\u{301}", kind: .unexpectedCharacter, range: 1..<3, note: "a combining mark ending a literal"),
    RejectRow(source: "rho\u{E9}", kind: .unexpectedCharacter, range: 3..<4, note: "a known name glued to an accent"),
    RejectRow(source: "1 2\u{E9}", kind: .unexpectedToken, range: 2..<3, note: "a glued accent does not hide an earlier error"),
    RejectRow(source: "1.2.3\u{E9}", kind: .invalidNumber, range: 0..<5, note: "a glued accent does not hide a bad literal"),
    RejectRow(source: "foo \u{E9}", kind: .unknownIdentifier("foo"), range: 0..<3, note: "a spaced accent is not glued"),
    RejectRow(source: "rho\u{A0}+ 1", kind: .unexpectedCharacter, range: 3..<4, note: "a non-breaking space"),
    RejectRow(source: "1 ^ 2", kind: .unexpectedCharacter, range: 2..<3, note: "no power operator"),

    // Unbalanced parentheses.
    RejectRow(source: "((1", kind: .unclosedParenthesis, range: 1..<2, note: "the innermost unclosed group"),
    RejectRow(source: "min(1, 2", kind: .unclosedParenthesis, range: 3..<4, note: "an unclosed call"),
    RejectRow(source: "1)", kind: .unmatchedClosingParenthesis, range: 1..<2, note: "a stray ) after an operand"),
    RejectRow(source: ")", kind: .unmatchedClosingParenthesis, range: 0..<1, note: "a lone )"),
    RejectRow(source: "1 + )", kind: .unmatchedClosingParenthesis, range: 4..<5, note: "a stray ) for an operand"),
    RejectRow(source: "(1))", kind: .unmatchedClosingParenthesis, range: 3..<4, note: "one ) too many"),

    // Missing operands.
    RejectRow(source: "1 +", kind: .unexpectedEnd, range: 2..<3, note: "a dangling operator"),
    RejectRow(source: "min(", kind: .unexpectedEnd, range: 3..<4, note: "a call cut off after ("),
    RejectRow(source: "min(1,", kind: .unexpectedEnd, range: 5..<6, note: "a call cut off after ,"),
    RejectRow(source: "-", kind: .unexpectedEnd, range: 0..<1, note: "a lone minus"),
    RejectRow(source: "1 + * 2", kind: .expectedOperand, range: 4..<5, note: "two operators in a row"),
    RejectRow(source: "+1", kind: .expectedOperand, range: 0..<1, note: "no unary plus"),
    RejectRow(source: "min(1, )", kind: .expectedOperand, range: 7..<8, note: "an empty argument"),
    RejectRow(source: "()", kind: .expectedOperand, range: 1..<2, note: "an empty group"),
    RejectRow(source: "", kind: .empty, range: 0..<0, note: "empty"),
    RejectRow(source: "  \t\r\n ", kind: .empty, range: 0..<6, note: "whitespace only"),

    // Literals.
    RejectRow(source: "1.", kind: .invalidNumber, range: 0..<2, note: "no trailing dot"),
    RejectRow(source: ".5", kind: .invalidNumber, range: 0..<2, note: "no leading dot"),
    RejectRow(source: "1.2.3", kind: .invalidNumber, range: 0..<5, note: "one fraction at most"),
    RejectRow(source: ".", kind: .invalidNumber, range: 0..<1, note: "a lone dot"),
    RejectRow(source: "1_000", kind: .invalidNumber, range: 0..<5, note: "no digit separators"),
    RejectRow(source: "1e3", kind: .invalidNumber, range: 0..<3, note: "no exponent"),
    RejectRow(source: "2rho", kind: .invalidNumber, range: 0..<4, note: "no implicit multiplication"),
    RejectRow(
        source: "1" + String(repeating: "0", count: 309),
        kind: .numberOutOfRange, range: 0..<310,
        note: "a literal that overflows to infinity"
    ),

    // Several problems: the first one reading left to right wins.
    RejectRow(source: "foo + #", kind: .unknownIdentifier("foo"), range: 0..<3, note: "name before bad character"),
    RejectRow(source: "1 2 #", kind: .unexpectedToken, range: 2..<3, note: "stray token before bad character"),
    RejectRow(source: "# 1 2", kind: .unexpectedCharacter, range: 0..<1, note: "bad character before stray token"),
    RejectRow(
        source: "min(1) + " + nested("(", 17),
        kind: .wrongArgumentCount(.min, expected: 2, found: 1), range: 0..<6,
        note: "arity before a later depth violation"
    ),
    RejectRow(source: "foo#", kind: .unknownIdentifier("foo"), range: 0..<3, note: "lookahead does not report early"),
]

@Suite("Formula grammar (spec §4 acceptance #1)")
struct FormulaGrammarTests {
    @Test("accepted formulas parse to the expected tree", arguments: acceptRows)
    func accepts(_ row: AcceptRow) {
        #expect(FormulaParser.parse(row.source) == .success(row.expected))
    }

    @Test("rejected formulas report the expected kind and range", arguments: rejectRows)
    func rejects(_ row: RejectRow) {
        #expect(FormulaParser.parse(row.source) == .failure(FormulaDiagnostic(kind: row.kind, range: row.range)))
    }

    @Test("all eight variables parse by their exact names")
    func variables() {
        #expect(FormulaVariable.allCases.count == 8)
        let names = Set(FormulaVariable.allCases.map(\.rawValue))
        #expect(names == [
            "intake_mean", "trend_delta", "trend_now", "trend_start",
            "window_days", "n_complete", "weigh_in_count", "rho",
        ])
        for variable in FormulaVariable.allCases {
            #expect(parsed(variable.rawValue) == .variable(variable))
            #expect(diagnostic(variable.rawValue.uppercased())?.kind == .unknownIdentifier(variable.rawValue.uppercased()))
        }
    }

    @Test("exactly four functions, each at its arity and no other")
    func functions() {
        #expect(FormulaFunction.allCases.map(\.rawValue) == ["min", "max", "clamp", "abs"])
        for function in FormulaFunction.allCases {
            for count in 0...4 {
                let source = function.rawValue + "(" + Array(repeating: "1", count: count).joined(separator: ", ") + ")"
                if count == function.arity {
                    #expect(parsed(source) == .call(function, Array(repeating: num(1), count: count)))
                } else {
                    #expect(diagnostic(source) == FormulaDiagnostic(
                        kind: .wrongArgumentCount(function, expected: function.arity, found: count),
                        range: 0..<source.utf16.count
                    ))
                }
            }
        }
    }

    @Test("the caps are 500 UTF-16 units and depth 16")
    func caps() {
        #expect(FormulaParser.maxLength == 500)
        #expect(FormulaParser.maxDepth == 16)
    }

    @Test("parsing never evaluates: a parsed formula is a plain value")
    func parsedValue() {
        // 1 + 2 stays an addition, and 1 / 0 parses: evaluation is not the
        // parser's job.
        #expect(parsed("1 + 2") == add(num(1), num(2)))
        #expect(parsed("1 / 0") == div(num(1), num(0)))
        // Spacing and redundant parentheses are not part of the value.
        let spaced = parsed("( 1 )+( 2 )")
        #expect(spaced == parsed("1+2"))
        #expect(spaced != nil)
        #expect(Set([parsed("1+2"), spaced]).count == 1)
    }
}

// MARK: - Properties

/// Deterministic generator so failures reproduce.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Fully parenthesized text for a tree, using only the grammar's syntax.
private func render(_ expression: E) -> String {
    switch expression {
    case .number(let value):
        return plainDecimal(value)
    case .variable(let variable):
        return variable.rawValue
    case .negate(let inner):
        return "-" + render(inner)
    case .binary(let op, let lhs, let rhs):
        return "(" + render(lhs) + " " + op.rawValue + " " + render(rhs) + ")"
    case .call(let function, let arguments):
        return function.rawValue + "(" + arguments.map(render).joined(separator: ", ") + ")"
    }
}

/// A non-negative finite Double as grammar-legal digits: Swift's shortest
/// round-trip text with any exponent shifted into the digits, so parsing it
/// gives the same Double back.
private func plainDecimal(_ value: Double) -> String {
    let text = "\(value)"
    guard let e = text.firstIndex(of: "e") else { return text }
    let exponent = Int(text[text.index(after: e)...]) ?? 0
    let parts = text[..<e].split(separator: ".", omittingEmptySubsequences: false)
    let whole = String(parts[0])
    let digits = whole + (parts.count > 1 ? String(parts[1]) : "")
    let point = whole.count + exponent
    if point <= 0 { return "0." + String(repeating: "0", count: -point) + digits }
    if point >= digits.count { return digits + String(repeating: "0", count: point - digits.count) }
    return String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
}

private func randomTree(_ rng: inout SplitMix64, depth: Int) -> E {
    let pick = depth == 0 ? Int.random(in: 0...1, using: &rng) : Int.random(in: 0...4, using: &rng)
    switch pick {
    case 0:
        // Built from literal text so the value is exactly what parsing it gives.
        let whole = Int.random(in: 0...99_999, using: &rng)
        let fraction = Int.random(in: 0...99, using: &rng)
        let text = fraction == 0 ? "\(whole)" : "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
        return num(Double(text) ?? 0)
    case 1:
        return v(FormulaVariable.allCases.randomElement(using: &rng) ?? .rho)
    case 2:
        return .negate(randomTree(&rng, depth: depth - 1))
    case 3:
        let op = FormulaBinaryOperator.allCases.randomElement(using: &rng) ?? .add
        return .binary(op, randomTree(&rng, depth: depth - 1), randomTree(&rng, depth: depth - 1))
    default:
        let function = FormulaFunction.allCases.randomElement(using: &rng) ?? .abs
        return .call(function, (0..<function.arity).map { _ in randomTree(&rng, depth: depth - 1) })
    }
}

/// UTF-16 offsets where a Character starts, plus the end.
private func characterBoundaries(_ source: String) -> Set<Int> {
    var offsets: Set<Int> = [0]
    var offset = 0
    for character in source {
        offset += character.utf16.count
        offsets.insert(offset)
    }
    return offsets
}

private func callsMatchArity(_ expression: E) -> Bool {
    switch expression {
    case .number(let value): value.isFinite
    case .variable: true
    case .negate(let inner): callsMatchArity(inner)
    case .binary(_, let lhs, let rhs): callsMatchArity(lhs) && callsMatchArity(rhs)
    case .call(let function, let arguments): arguments.count == function.arity && arguments.allSatisfy(callsMatchArity)
    }
}

private let fuzzPieces = [
    "1", "0.5", "42", "rho", "trend_delta", "Rho", "foo", "min", "max", "clamp", "abs",
    "(", ")", ",", "+", "-", "*", "/", " ", "\t", "\r\n", ".", "e", "#", "😀", "👍🏽",
    "\u{A0}", "\u{301}", "é", "_", "9", "^", "((((((((((", "))", "1e400",
    String(repeating: "9", count: 320),
]

/// Parses `text`, checks what must hold for any input, and names the
/// outcome: "ok" or the diagnostic kind.
private func checkInvariants(_ text: String) -> String {
    switch FormulaParser.parse(text) {
    case .success(let tree):
        #expect(callsMatchArity(tree), "\(text)")
        let rendered = render(tree)
        if rendered.utf16.count <= FormulaParser.maxLength {
            #expect(FormulaParser.parse(rendered) == .success(tree), "\(text)")
        }
        return "ok"
    case .failure(let error):
        let boundaries = characterBoundaries(text)
        #expect(boundaries.contains(error.range.lowerBound), "\(text)")
        #expect(boundaries.contains(error.range.upperBound), "\(text)")
        #expect(error.range.upperBound <= text.utf16.count, "\(text)")
        #expect(!error.range.isEmpty || text.isEmpty, "\(text)")
        let label = String(describing: error.kind)
        return String(label.prefix { $0 != "(" })
    }
}

@Suite("Formula grammar properties")
struct FormulaGrammarPropertyTests {
    @Test("rendering a tree and parsing it back gives the same tree")
    func roundTrip() {
        var rng = SplitMix64(state: 0xF0_0D)
        var checked = 0
        for _ in 0..<2_000 {
            let tree = randomTree(&rng, depth: Int.random(in: 0...5, using: &rng))
            let text = render(tree)
            let result = FormulaParser.parse(text)
            if text.utf16.count > FormulaParser.maxLength {
                #expect(result == .failure(FormulaDiagnostic(
                    kind: .tooLong(length: text.utf16.count),
                    range: FormulaParser.maxLength..<text.utf16.count
                )))
                continue
            }
            #expect(result == .success(tree), "\(text)")
            checked += 1
        }
        #expect(checked > 1_000)
    }

    @Test("random text never traps; diagnostics land on character boundaries")
    func fuzz() {
        var rng = SplitMix64(state: 0xBEEF)
        var outcomes: [String: Int] = [:]
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...40, using: &rng)
            let text = (0..<count).map { _ in fuzzPieces.randomElement(using: &rng) ?? "" }.joined()
            outcomes[checkInvariants(text), default: 0] += 1
        }
        // Mostly junk by design; this side covers lexical and early errors.
        #expect(outcomes.keys.contains("unexpectedCharacter"))
        #expect(outcomes.keys.contains("invalidNumber"))
        #expect(outcomes.keys.contains("unknownIdentifier"))
        #expect(outcomes.keys.contains("numberOutOfRange"))
        #expect(outcomes.keys.contains("tooLong"))
    }

    @Test("one-edit mutations of valid formulas never trap and keep the invariants")
    func mutationFuzz() {
        var rng = SplitMix64(state: 0x5EED)
        var outcomes: [String: Int] = [:]
        for _ in 0..<5_000 {
            var characters = Array(render(randomTree(&rng, depth: Int.random(in: 1...7, using: &rng))))
            switch Int.random(in: 0...3, using: &rng) {
            case 0 where !characters.isEmpty:
                let at = Int.random(in: 0..<characters.count, using: &rng)
                let length = Int.random(in: 1...3, using: &rng)
                characters.removeSubrange(at..<min(at + length, characters.count))
            case 1:
                let at = Int.random(in: 0...characters.count, using: &rng)
                characters.insert(contentsOf: fuzzPieces.randomElement(using: &rng) ?? "", at: at)
            case 3:
                // Push nesting toward the depth cap.
                let levels = Int.random(in: 5...12, using: &rng)
                characters = Array(String(repeating: "(", count: levels)) + characters
                    + Array(String(repeating: ")", count: levels))
            default:
                if characters.count > 1 {
                    let a = Int.random(in: 0..<characters.count, using: &rng)
                    let b = Int.random(in: 0..<characters.count, using: &rng)
                    characters.swapAt(a, b)
                }
            }
            outcomes[checkInvariants(String(characters)), default: 0] += 1
        }
        #expect(outcomes["ok", default: 0] > 500, "\(outcomes)")
        for kind in [
            "tooDeep", "unexpectedToken", "expectedOperand", "unexpectedEnd",
            "unclosedParenthesis", "unmatchedClosingParenthesis", "unknownIdentifier",
            "wrongArgumentCount", "unexpectedCharacter", "invalidNumber",
        ] {
            #expect(outcomes[kind, default: 0] > 0, "never produced \(kind): \(outcomes)")
        }
    }

    @Test("long inputs stay bounded: deep unary minus and very long text")
    func longInputs() {
        let minuses = String(repeating: "-", count: 499) + "1"
        let tree = (0..<499).reduce(num(1)) { inner, _ in .negate(inner) }
        #expect(parsed(minuses) == tree)
        let huge = String(repeating: "(", count: 1_000_000)
        #expect(diagnostic(huge) == FormulaDiagnostic(kind: .tooLong(length: 1_000_000), range: 500..<1_000_000))
    }
}
