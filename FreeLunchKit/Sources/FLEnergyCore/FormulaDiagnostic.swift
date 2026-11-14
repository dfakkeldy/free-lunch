// SPDX-License-Identifier: GPL-3.0-or-later

/// Why a formula failed to parse, and where.
///
/// `range` is in UTF-16 code units from the start of the text, the unit
/// `NSString`, `NSRange` and text views use, so an editor can highlight it
/// directly. A multi-unit character (an emoji is two units) is never split:
/// a range always starts and ends on a character boundary.
public struct FormulaDiagnostic: Error, Sendable, Hashable {
    public let kind: Kind
    public let range: Range<Int>

    public init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    public enum Kind: Sendable, Hashable {
        /// Nothing but whitespace. The range covers the whole text (empty
        /// for empty text).
        case empty
        /// More than ``FormulaParser/maxLength`` UTF-16 units. `length` is
        /// the text's length in that unit; the range runs from the first
        /// character that does not fit to the end.
        case tooLong(length: Int)
        /// A parenthesis group or call argument list opens a level past
        /// ``FormulaParser/maxDepth``. The range is the opening `(`.
        case tooDeep
        /// A character outside the grammar's alphabet (`#`, an emoji, a
        /// non-breaking space, an accented letter). The range is that one
        /// character, even when it follows a name directly (`ó` in `rhó`).
        case unexpectedCharacter
        /// A run starting with a digit or `.` that is not digits with an
        /// optional `.digits` fraction: `1.`, `.5`, `1.2.3`, `1e3`, `2rho`.
        case invalidNumber
        /// A well-formed literal too large for a Double.
        case numberOutOfRange
        /// A name that is not valid where it appears: not one of the eight
        /// variables in value position (`Rho`, `foo`, a bare `min`), or not
        /// one of the four functions in call position (`rho(1)`).
        case unknownIdentifier(String)
        /// A call with the wrong number of arguments. The range runs from the
        /// function name through its closing `)`. `expected` is always
        /// `function.arity`, repeated so a message needs nothing else.
        case wrongArgumentCount(FormulaFunction, expected: Int, found: Int)
        /// A complete operand is followed by something that cannot continue
        /// it, such as `2` in `1 2` or `,` outside a call.
        case unexpectedToken
        /// An operator, `,` or `)` where an operand belongs, as in `1 + * 2`,
        /// `+1` (there is no unary plus) or `min(1, )`.
        case expectedOperand
        /// The text ends where an operand belongs. The range is the last
        /// token, the one left dangling (`+` in `1 +`, `(` in `min(`).
        case unexpectedEnd
        /// The text ends inside a group. The range is the innermost unclosed
        /// `(`.
        case unclosedParenthesis
        /// A `)` with no open group to close.
        case unmatchedClosingParenthesis
    }
}
