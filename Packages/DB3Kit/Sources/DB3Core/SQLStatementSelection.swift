import Foundation

/// Resolves an explicit selection or the PostgreSQL statement at a UTF-16 caret.
/// This is CPU work: callers should run it outside the main actor. The scanner
/// retains one UTF-16 buffer and two ranges, never a String per statement.
public enum SQLStatementSelection {
    public static func statement(in sql: String, selection: NSRange) throws -> String? {
        try Task.checkCancellation()
        let source = sql as NSString
        let count = source.length
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= count, selection.length <= count - selection.location else {
            throw DatabaseError("The SQL selection is outside the document. Select the statement again.")
        }
        func isScalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < count else { return true }
            return !(0xD800...0xDBFF).contains(source.character(at: offset - 1)) ||
                !(0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        guard isScalarBoundary(selection.location), isScalarBoundary(selection.location + selection.length) else {
            throw DatabaseError("The SQL selection splits a Unicode character. Select the statement again.")
        }

        // Highlighted SQL is returned unchanged. PostgreSQL's extended protocol
        // remains responsible for enforcing a single statement in that text.
        let text = selection.length > 0 ? source.substring(with: selection) : sql
        var units = ContiguousArray<UInt16>()
        units.reserveCapacity(selection.length > 0 ? selection.length : count)
        for unit in text.utf16 {
            if units.count & 4_095 == 0 { try Task.checkCancellation() }
            units.append(unit)
        }
        var scanner = StatementScanner(units: units)
        if selection.length > 0 {
            return try scanner.hasCode() ? text : nil
        }
        guard let range = try scanner.statementRange(at: selection.location) else { return nil }
        try Task.checkCancellation()
        return source.substring(with: range)
    }
}

private struct StatementScanner {
    let units: ContiguousArray<UInt16>
    private var cursor = 0
    private var nextCancellationCheck = 0

    init(units: ContiguousArray<UInt16>) { self.units = units }

    mutating func hasCode() throws -> Bool {
        while cursor < units.count {
            try checkpoint()
            if try skipTrivia() { continue }
            if units[cursor] != 59 { return true }
            cursor += 1
        }
        return false
    }

    mutating func statementRange(at caret: Int) throws -> NSRange? {
        var start = 0
        var containsCode = false
        var previous: NSRange?
        var previousWasBegin = false
        var previousWasEscapeString = false
        var newlineAfterString = false
        var parenthesesDepth = 0
        while cursor < units.count {
            try checkpoint()
            let beforeTrivia = cursor
            if try skipTrivia() {
                if previousWasEscapeString {
                    for index in beforeTrivia..<cursor {
                        if units[index] == 10 || units[index] == 13 { newlineAfterString = true; break }
                        if index & 4_095 == 0 { try Task.checkCancellation() }
                    }
                }
                continue
            }
            let unit = units[cursor]
            if unit == 59, parenthesesDepth == 0 {
                if containsCode {
                    let range = NSRange(location: start, length: cursor + 1 - start)
                    if caret <= cursor { return range }
                    previous = range
                } else if caret <= cursor, let previous { return previous }
                cursor += 1
                start = cursor
                containsCode = false
                previousWasBegin = false
                previousWasEscapeString = false
                newlineAfterString = false
                continue
            }
            containsCode = true
            if unit == 39 {
                let escape = previousWasEscapeString && newlineAfterString
                try quoted(39, escapes: escape)
                previousWasEscapeString = escape
                newlineAfterString = false
                previousWasBegin = false
                continue
            }
            previousWasEscapeString = false
            newlineAfterString = false
            if unit == 34 {
                try quoted(34, escapes: false)
                previousWasBegin = false
            } else if isIdentifierStart(unit) {
                let tokenStart = cursor
                cursor += 1
                while cursor < units.count, isIdentifierPart(units[cursor]) {
                    try checkpoint(); cursor += 1
                }
                let length = cursor - tokenStart
                if length == 1, (unit == 69 || unit == 101), cursor < units.count, units[cursor] == 39 {
                    try quoted(39, escapes: true)
                    previousWasEscapeString = true
                    previousWasBegin = false
                } else {
                    if previousWasBegin, matchesASCII("ATOMIC", at: tokenStart, length: length) {
                        throw DatabaseError("A BEGIN ATOMIC body needs an explicit selection. Highlight the complete CREATE FUNCTION or CREATE PROCEDURE statement before running it.")
                    }
                    previousWasBegin = matchesASCII("BEGIN", at: tokenStart, length: length)
                }
            } else if unit == 36, let delimiterEnd = try dollarDelimiterEnd() {
                try dollarQuoted(delimiterEnd: delimiterEnd)
                previousWasBegin = false
            } else {
                // CREATE RULE allows a parenthesized list of actions separated
                // by semicolons. Never extract and execute an inner action.
                if unit == 40 { parenthesesDepth += 1 }
                if unit == 41 {
                    guard parenthesesDepth > 0 else {
                        throw DatabaseError("Fix the unmatched SQL parenthesis before running this statement.")
                    }
                    parenthesesDepth -= 1
                }
                cursor += 1
                previousWasBegin = false
            }
        }
        guard parenthesesDepth == 0 else {
            throw DatabaseError("Close the unfinished SQL parentheses before running this statement.")
        }
        if containsCode { return NSRange(location: start, length: units.count - start) }
        return previous
    }

    private mutating func checkpoint() throws {
        if cursor >= nextCancellationCheck {
            try Task.checkCancellation()
            nextCancellationCheck = cursor + 4_096
        }
    }

    private func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 32 || (9...13).contains(unit)
    }

    private func isIdentifierStart(_ unit: UInt16) -> Bool {
        unit == 95 || (65...90).contains(unit) || (97...122).contains(unit) || unit >= 128
    }

    private func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || (48...57).contains(unit) || unit == 36
    }

    private func matchesASCII(_ token: StaticString, at start: Int, length: Int) -> Bool {
        token.withUTF8Buffer { bytes in
            guard length == bytes.count else { return false }
            for index in 0..<length {
                let unit = units[start + index]
                let uppercase = (97...122).contains(unit) ? unit - 32 : unit
                if uppercase != UInt16(bytes[index]) { return false }
            }
            return true
        }
    }

    /// Comments are whitespace, including PostgreSQL's nested block comments.
    private mutating func skipTrivia() throws -> Bool {
        if isWhitespace(units[cursor]) { cursor += 1; return true }
        guard cursor + 1 < units.count else { return false }
        if units[cursor] == 45, units[cursor + 1] == 45 {
            cursor += 2
            while cursor < units.count, units[cursor] != 10, units[cursor] != 13 {
                try checkpoint(); cursor += 1
            }
            return true
        }
        if units[cursor] == 47, units[cursor + 1] == 42 {
            cursor += 2
            var depth = 1
            while cursor < units.count {
                try checkpoint()
                if cursor + 1 < units.count, units[cursor] == 47, units[cursor + 1] == 42 {
                    depth += 1; cursor += 2
                } else if cursor + 1 < units.count, units[cursor] == 42, units[cursor + 1] == 47 {
                    depth -= 1; cursor += 2
                    if depth == 0 { return true }
                } else { cursor += 1 }
            }
            throw DatabaseError("Close the unfinished SQL block comment before running this statement.")
        }
        return false
    }

    private mutating func quoted(_ quote: UInt16, escapes: Bool) throws {
        cursor += 1
        while cursor < units.count {
            try checkpoint()
            if units[cursor] == quote {
                cursor += 1
                if cursor < units.count, units[cursor] == quote { cursor += 1 }
                else { return }
            } else if units[cursor] == 92, escapes {
                cursor += min(2, units.count - cursor)
            } else if units[cursor] == 92, quote == 39 {
                let start = cursor
                repeat { try checkpoint(); cursor += 1 } while cursor < units.count && units[cursor] == 92
                if (cursor - start) % 2 == 1, cursor < units.count, units[cursor] == 39 {
                    throw DatabaseError("Backslash-quoted text depends on the session's string settings. Use an E'…' escape string or highlight the complete statement explicitly.")
                }
            } else { cursor += 1 }
        }
        throw DatabaseError("Close the unfinished SQL quote before running this statement.")
    }

    private mutating func dollarDelimiterEnd() throws -> Int? {
        var index = cursor + 1
        if index < units.count, units[index] == 36 { return index + 1 }
        guard index < units.count, isIdentifierStart(units[index]) else { return nil }
        index += 1
        while index < units.count, isIdentifierPart(units[index]), units[index] != 36 {
            if index & 4_095 == 0 { try Task.checkCancellation() }
            index += 1
        }
        return index < units.count && units[index] == 36 ? index + 1 : nil
    }

    private mutating func dollarQuoted(delimiterEnd: Int) throws {
        let delimiterStart = cursor
        let length = delimiterEnd - delimiterStart
        cursor = delimiterEnd
        while cursor < units.count {
            try checkpoint()
            guard units[cursor] == 36 else { cursor += 1; continue }
            var matched = 1
            while matched < length, cursor + matched < units.count,
                  units[cursor + matched] == units[delimiterStart + matched] {
                if matched & 4_095 == 0 { try Task.checkCancellation() }
                matched += 1
            }
            if matched == length { cursor += length; return }
            // A tag has no internal dollar sign, so a failed prefix contains no
            // possible delimiter start. Advancing over it keeps scanning linear.
            cursor += matched
        }
        throw DatabaseError("Close the unfinished dollar-quoted SQL body before running this statement.")
    }
}
