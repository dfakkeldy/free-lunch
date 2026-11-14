// SPDX-License-Identifier: GPL-3.0-or-later

/// Parses §4 formula text into a ``FormulaExpression``, or reports the first
/// problem with its position. It only parses: nothing is evaluated, and no
/// input traps.
///
/// Grammar (whitespace is space, tab, LF, CR and CRLF, allowed between any
/// two tokens):
///
///     formula  = sum END
///     sum      = product { ("+" | "-") product }
///     product  = unary { ("*" | "/") unary }
///     unary    = { "-" } primary
///     primary  = number | variable | function "(" [ sum { "," sum } ] ")"
///              | "(" sum ")"
///     number   = digit { digit } [ "." digit { digit } ]
///
/// The four binary operators are left-associative, `*` and `/` bind tighter
/// than `+` and `-`, and unary minus binds tighter than both (`-2 * 3` is
/// `(-2) * 3`). There is no unary plus and no exponent in literals.
///
/// Limits:
/// - Length: at most ``maxLength`` UTF-16 code units, counted before
///   anything else is read. Diagnostic ranges use the same unit.
/// - Depth: every parenthesis group and every call's argument list opens one
///   level. ``maxDepth`` levels parse; the `(` that would open one more is
///   rejected. Unary minus does not count; the length cap bounds it.
/// - Arity: each function takes exactly ``FormulaFunction/arity`` arguments.
///
/// Length is checked first. Otherwise, when text has several problems, the
/// one reached first reading left to right is reported, whatever its kind.
/// A function name may be separated from its `(` by whitespace.
public enum FormulaParser {
    /// Maximum formula length, in UTF-16 code units.
    public static let maxLength = 500
    /// Maximum nesting of parenthesis groups and call argument lists.
    public static let maxDepth = 16

    public static func parse(_ source: String) -> Result<FormulaExpression, FormulaDiagnostic> {
        let length = source.utf16.count
        if length > maxLength {
            return .failure(FormulaDiagnostic(kind: .tooLong(length: length), range: overflowStart(of: source)..<length))
        }
        let tokens = FormulaLexer.tokens(of: source)
        if tokens.count == 1 {
            // Only the end token: nothing but whitespace.
            return .failure(FormulaDiagnostic(kind: .empty, range: 0..<length))
        }
        var parser = Parser(tokens: tokens)
        do {
            return .success(try parser.formula())
        } catch {
            return .failure(error)
        }
    }

    /// UTF-16 offset of the first character that ends past ``maxLength``.
    private static func overflowStart(of source: String) -> Int {
        var offset = 0
        for character in source {
            let next = offset + character.utf16.count
            if next > maxLength { return offset }
            offset = next
        }
        return offset
    }
}

// MARK: - Lexer

struct FormulaToken: Equatable {
    enum Kind: Equatable {
        case number(Double)
        case identifier(String)
        case plus, minus, star, slash
        case leftParen, rightParen, comma
        /// A lexical error, reported when the parser reaches it.
        case invalid(FormulaDiagnostic.Kind)
        case end
    }

    let kind: Kind
    /// UTF-16 offsets.
    let range: Range<Int>
}

enum FormulaLexer {
    /// Tokens of `source`, always ending with one `.end` token. Lexical
    /// errors become `.invalid` tokens so that an earlier syntax error still
    /// wins.
    static func tokens(of source: String) -> [FormulaToken] {
        // Lex by Character so a multi-unit character is one token and its
        // range covers all of its UTF-16 units.
        var characters: [(ascii: UInt8?, start: Int, end: Int)] = []
        var offset = 0
        for character in source {
            let end = offset + character.utf16.count
            // asciiValue is nil for anything outside ASCII, including an ASCII
            // base with a combining mark. CRLF is one Character whose
            // asciiValue is LF.
            characters.append((character.asciiValue, offset, end))
            offset = end
        }

        var tokens: [FormulaToken] = []
        var index = 0
        while index < characters.count {
            let (ascii, start, end) = characters[index]
            guard let byte = ascii else {
                tokens.append(FormulaToken(kind: .invalid(.unexpectedCharacter), range: start..<end))
                index += 1
                continue
            }
            if isWhitespace(byte) {
                index += 1
                continue
            }
            if isDigit(byte) || byte == UInt8(ascii: ".") || isIdentifierStart(byte) {
                // A word: an identifier, or a number candidate. A number run
                // also swallows letters and dots so `1e3` or `1.2.3` is one
                // bad literal rather than a literal followed by a name.
                let isNumber = !isIdentifierStart(byte)
                var text: [UInt8] = [byte]
                var last = end
                index += 1
                while index < characters.count, let next = characters[index].ascii,
                      isIdentifierContinue(next) || (isNumber && next == UInt8(ascii: ".")) {
                    text.append(next)
                    last = characters[index].end
                    index += 1
                }
                if index < characters.count, characters[index].ascii == nil {
                    // A word running straight into a non-ASCII character
                    // (`rhó` is `rh` then `ó`): blame the character, not a
                    // truncated name.
                    let bad = characters[index]
                    tokens.append(FormulaToken(kind: .invalid(.unexpectedCharacter), range: bad.start..<bad.end))
                    index += 1
                    continue
                }
                let word = String(decoding: text, as: UTF8.self)
                let kind: FormulaToken.Kind = isNumber ? numberKind(word) : .identifier(word)
                tokens.append(FormulaToken(kind: kind, range: start..<last))
                continue
            }
            let kind: FormulaToken.Kind
            switch byte {
            case UInt8(ascii: "+"): kind = .plus
            case UInt8(ascii: "-"): kind = .minus
            case UInt8(ascii: "*"): kind = .star
            case UInt8(ascii: "/"): kind = .slash
            case UInt8(ascii: "("): kind = .leftParen
            case UInt8(ascii: ")"): kind = .rightParen
            case UInt8(ascii: ","): kind = .comma
            default: kind = .invalid(.unexpectedCharacter)
            }
            tokens.append(FormulaToken(kind: kind, range: start..<end))
            index += 1
        }
        tokens.append(FormulaToken(kind: .end, range: offset..<offset))
        return tokens
    }

    /// Digits with an optional `.digits` fraction, finite as a Double.
    private static func numberKind(_ word: String) -> FormulaToken.Kind {
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        let wellFormed = (1...2).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy(isDigit) }
        guard wellFormed else { return .invalid(.invalidNumber) }
        // Double(String) rounds correctly and gives +infinity on overflow.
        guard let value = Double(word), value.isFinite else { return .invalid(.numberOutOfRange) }
        return .number(value)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || byte == UInt8(ascii: "_")
    }

    private static func isIdentifierContinue(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || isDigit(byte)
    }
}

// MARK: - Parser

private struct Parser {
    let tokens: [FormulaToken]
    var index = 0
    var depth = 0

    init(tokens: [FormulaToken]) {
        self.tokens = tokens
    }

    /// The last token is `.end`, so this never runs off the array.
    var current: FormulaToken { tokens[index] }

    mutating func advance() {
        if index < tokens.count - 1 { index += 1 }
    }

    mutating func formula() throws(FormulaDiagnostic) -> FormulaExpression {
        let expression = try sum()
        switch current.kind {
        case .end: return expression
        case .invalid(let kind): throw FormulaDiagnostic(kind: kind, range: current.range)
        case .rightParen: throw FormulaDiagnostic(kind: .unmatchedClosingParenthesis, range: current.range)
        default: throw FormulaDiagnostic(kind: .unexpectedToken, range: current.range)
        }
    }

    mutating func sum() throws(FormulaDiagnostic) -> FormulaExpression {
        var lhs = try product()
        while true {
            let op: FormulaBinaryOperator
            switch current.kind {
            case .plus: op = .add
            case .minus: op = .subtract
            default: return lhs
            }
            advance()
            lhs = .binary(op, lhs, try product())
        }
    }

    mutating func product() throws(FormulaDiagnostic) -> FormulaExpression {
        var lhs = try unary()
        while true {
            let op: FormulaBinaryOperator
            switch current.kind {
            case .star: op = .multiply
            case .slash: op = .divide
            default: return lhs
            }
            advance()
            lhs = .binary(op, lhs, try unary())
        }
    }

    mutating func unary() throws(FormulaDiagnostic) -> FormulaExpression {
        // Counted in a loop, not by recursion, so a long run of minuses
        // costs no stack.
        var negations = 0
        while current.kind == .minus {
            negations += 1
            advance()
        }
        var expression = try primary()
        for _ in 0..<negations {
            expression = .negate(expression)
        }
        return expression
    }

    mutating func primary() throws(FormulaDiagnostic) -> FormulaExpression {
        let token = current
        switch token.kind {
        case .number(let value):
            advance()
            return .number(value)

        case .identifier(let name):
            // current is not .end, so a next token exists.
            if tokens[index + 1].kind == .leftParen {
                guard let function = FormulaFunction(rawValue: name) else {
                    throw FormulaDiagnostic(kind: .unknownIdentifier(name), range: token.range)
                }
                advance()
                return try call(function, name: token)
            }
            guard let variable = FormulaVariable(rawValue: name) else {
                throw FormulaDiagnostic(kind: .unknownIdentifier(name), range: token.range)
            }
            advance()
            return .variable(variable)

        case .leftParen:
            try open(token)
            advance()
            let inner = try sum()
            guard current.kind == .rightParen else { throw unclosed(token) }
            close()
            return inner

        case .end:
            // Empty text never gets here, so a previous token exists.
            let dangling = index > 0 ? tokens[index - 1].range : token.range
            throw FormulaDiagnostic(kind: .unexpectedEnd, range: dangling)

        case .invalid(let kind):
            throw FormulaDiagnostic(kind: kind, range: token.range)

        case .rightParen:
            throw FormulaDiagnostic(kind: depth == 0 ? .unmatchedClosingParenthesis : .expectedOperand, range: token.range)

        case .plus, .minus, .star, .slash, .comma:
            throw FormulaDiagnostic(kind: .expectedOperand, range: token.range)
        }
    }

    /// Parses an argument list; `current` is its `(`.
    mutating func call(_ function: FormulaFunction, name: FormulaToken) throws(FormulaDiagnostic) -> FormulaExpression {
        let openToken = current
        try open(openToken)
        advance()
        var arguments: [FormulaExpression] = []
        if current.kind != .rightParen {
            argumentLoop: while true {
                arguments.append(try sum())
                switch current.kind {
                case .comma: advance()
                case .rightParen: break argumentLoop
                default: throw unclosed(openToken)
                }
            }
        }
        let closeToken = current
        close()
        guard arguments.count == function.arity else {
            throw FormulaDiagnostic(
                kind: .wrongArgumentCount(function, expected: function.arity, found: arguments.count),
                range: name.range.lowerBound..<closeToken.range.upperBound
            )
        }
        return .call(function, arguments)
    }

    mutating func open(_ token: FormulaToken) throws(FormulaDiagnostic) {
        depth += 1
        if depth > FormulaParser.maxDepth {
            throw FormulaDiagnostic(kind: .tooDeep, range: token.range)
        }
    }

    /// Consumes the current `)`.
    mutating func close() {
        depth -= 1
        advance()
    }

    /// The error when a group opened by `openToken` is not followed by `)`.
    func unclosed(_ openToken: FormulaToken) -> FormulaDiagnostic {
        switch current.kind {
        case .end: FormulaDiagnostic(kind: .unclosedParenthesis, range: openToken.range)
        case .invalid(let kind): FormulaDiagnostic(kind: kind, range: current.range)
        default: FormulaDiagnostic(kind: .unexpectedToken, range: current.range)
        }
    }
}
