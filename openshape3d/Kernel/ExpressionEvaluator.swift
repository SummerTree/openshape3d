//
//  ExpressionEvaluator.swift
//  openshape3d
//
//  Tiny, self-contained arithmetic evaluator for dimension input fields
//  (plan §C2, spec §18): lets the user type "25.4/2", "10 + 5", "(1+2)*3"
//  into a dimension box and have it resolve to a number. Supports + - * /,
//  parentheses, unary minus, and a trailing unit suffix ("20 mm") which is
//  ignored. Pure Swift recursive descent — deliberately NOT NSExpression,
//  which raises an uncatchable Obj-C exception on malformed input.
//
//  nonisolated + Double math to match the kernel.
//

import Foundation

nonisolated enum ExpressionEvaluator {

    /// Evaluate `text` to a Double, or nil when it is empty / malformed.
    /// A trailing alphabetic unit suffix (mm, cm, in, "), whitespace, and a
    /// leading "=" are tolerated.
    static func evaluate(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("=") { s.removeFirst() }
        // Drop a trailing unit suffix: keep the numeric/operator prefix.
        s = stripTrailingUnit(s)
        guard !s.isEmpty else { return nil }
        var parser = Parser(Array(s))
        guard let value = parser.parseExpression(), parser.atEnd else { return nil }
        guard value.isFinite else { return nil }
        return value
    }

    /// Remove a trailing run of letters / quote (a unit like "mm" or `"`).
    private static func stripTrailingUnit(_ s: String) -> String {
        var chars = Array(s)
        while let last = chars.last, last.isLetter || last == "\"" || last == "'" || last == " " {
            chars.removeLast()
        }
        return String(chars)
    }

    // MARK: - Recursive descent

    private struct Parser {
        private let chars: [Character]
        private var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool {
            mutating get {
                skipSpaces()
                return i >= chars.count
            }
        }

        private mutating func skipSpaces() {
            while i < chars.count, chars[i] == " " { i += 1 }
        }

        private mutating func peek() -> Character? {
            skipSpaces()
            return i < chars.count ? chars[i] : nil
        }

        private mutating func consume() -> Character? {
            skipSpaces()
            guard i < chars.count else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        // expression := term (('+'|'-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                _ = consume()
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := factor (('*'|'/') factor)*
        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                _ = consume()
                guard let rhs = parseFactor() else { return nil }
                if op == "/" {
                    guard rhs != 0 else { return nil }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        // factor := '-' factor | '(' expression ')' | number
        private mutating func parseFactor() -> Double? {
            guard let c = peek() else { return nil }
            if c == "-" {
                _ = consume()
                guard let v = parseFactor() else { return nil }
                return -v
            }
            if c == "+" {
                _ = consume()
                return parseFactor()
            }
            if c == "(" {
                _ = consume()
                guard let v = parseExpression() else { return nil }
                guard peek() == ")" else { return nil }
                _ = consume()
                return v
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Double? {
            skipSpaces()
            var digits = ""
            var sawDot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber {
                    digits.append(c)
                    i += 1
                } else if c == "." && !sawDot {
                    sawDot = true
                    digits.append(c)
                    i += 1
                } else {
                    break
                }
            }
            return digits.isEmpty ? nil : Double(digits)
        }
    }
}
