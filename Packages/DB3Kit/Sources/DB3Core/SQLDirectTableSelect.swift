import Foundation

/// A conservative shape check for direct editing of already executed SELECTs.
/// It proves one named FROM source, never eligibility by result OID alone (which
/// cannot distinguish aliases in a self-join). Catalog/type/PK/provenance checks
/// are still required: a named relation can be a view, inherited table, etc.
/// This does not execute SQL, rewrite it, or attempt full syntax validation.
public enum SQLDirectTableSelect {
    public static func isEligible(_ sql: String) throws -> Bool {
        do {
            var parser = DirectSelectParser(sql)
            return try parser.parse()
        } catch is DirectSelectSyntaxError { return false }
    }
}

private enum DirectSelectSyntaxError: Error { case unsupported }

private enum DirectSelectToken: Equatable {
    case word(String), identifier, literal, symbol(UInt8)
    var keyword: String? { if case .word(let word) = self { word } else { nil } }
    var isIdentifier: Bool {
        switch self {
        case .identifier: true
        case .word(let word): !Self.reserved.contains(word)
        default: false
        }
    }
    private static let reserved: Set<String> = [
        "SELECT", "WITH", "FROM", "WHERE", "ORDER", "BY", "LIMIT", "OFFSET", "FETCH", "FOR",
        "JOIN", "CROSS", "INNER", "OUTER", "LEFT", "RIGHT", "FULL", "NATURAL", "LATERAL", "ON", "USING",
        "GROUP", "HAVING", "WINDOW", "UNION", "INTERSECT", "EXCEPT", "INTO", "AS", "ONLY", "TABLESAMPLE",
        "VALUES", "TABLE", "INSERT", "UPDATE", "DELETE", "MERGE", "RETURNING", "SET", "BEGIN", "COMMIT",
        "ROLLBACK", "END", "ALL", "DISTINCT", "AND", "OR", "NOT", "TRUE", "FALSE", "NULL"
    ]
}

private struct DirectSelectParser {
    private var lexer: DirectSelectLexer
    init(_ sql: String) { lexer = DirectSelectLexer(sql) }
    private static let clauses: Set<String> = ["WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR"]
    private static let forbidden: Set<String> = ["INTO", "JOIN", "UNION", "INTERSECT", "EXCEPT", "GROUP", "HAVING", "WINDOW"]

    mutating func parse() throws -> Bool {
        guard try lexer.next() == .word("SELECT") else { return false }
        var depth = 0, projection = false, foundFrom = false
        while let token = try lexer.next() {
            if token == .word("SELECT") || token == .word("WITH") { return false }
            if depth == 0, token == .word("FROM") { foundFrom = true; break }
            if depth == 0, let keyword = token.keyword,
               Self.forbidden.contains(keyword) || Self.clauses.contains(keyword) { return false }
            guard token != .symbol(59), try balance(token, depth: &depth) else { return false }
            if token != .word("ALL"), token != .word("DISTINCT") { projection = true }
        }
        guard foundFrom, projection, depth == 0 else { return false }

        var token = try lexer.next()
        if token == .word("ONLY") { token = try lexer.next() }
        guard token?.isIdentifier == true else { return false }
        token = try lexer.next()
        if token == .symbol(46) { // One optional schema qualifier, quoted independently.
            guard try lexer.next()?.isIdentifier == true else { return false }
            token = try lexer.next()
        }
        if token == .word("AS") {
            guard try lexer.next()?.isIdentifier == true else { return false }
            token = try lexer.next()
        } else if token?.isIdentifier == true {
            token = try lexer.next()
        }

        // Any source comma, JOIN, function call, parenthesized source, alias
        // column list, TABLESAMPLE, or third qualifier fails this transition.
        var activeClause: String?, clauseHasBody = false, seen = Set<String>()
        while let current = token {
            if current == .symbol(59) {
                guard depth == 0, activeClause == nil || clauseHasBody else { return false }
                return try lexer.next() == nil
            }
            if current == .word("SELECT") { return false } // Includes nested SELECTs.
            if current == .word("WITH"), !(depth == 0 && activeClause == "FETCH") { return false }
            if depth == 0, let keyword = current.keyword {
                if Self.forbidden.contains(keyword) || keyword == "FROM" || keyword == "TABLESAMPLE" { return false }
                if Self.clauses.contains(keyword) {
                    guard activeClause == nil || clauseHasBody, seen.insert(keyword).inserted else { return false }
                    if keyword == "LIMIT", seen.contains("FETCH") { return false }
                    if keyword == "FETCH", seen.contains("LIMIT") { return false }
                    if keyword == "ORDER", try lexer.next() != .word("BY") { return false }
                    activeClause = keyword; clauseHasBody = false
                    token = try lexer.next()
                    continue
                }
            }
            guard activeClause != nil, try balance(current, depth: &depth) else { return false }
            clauseHasBody = true
            token = try lexer.next()
        }
        return depth == 0 && (activeClause == nil || clauseHasBody)
    }

    private func balance(_ token: DirectSelectToken, depth: inout Int) throws -> Bool {
        if token == .symbol(40) { depth += 1 }
        else if token == .symbol(41) {
            guard depth > 0 else { return false }
            depth -= 1
        }
        return true
    }
}

/// Streaming storage is bounded independently of document length: keyword text
/// is capped at 64 bytes, dollar tags at 256. CPU work checks cancellation.
private struct DirectSelectLexer {
    private let bytes: String.UTF8View
    private var cursor: String.UTF8View.Index
    private var visited = 0
    init(_ sql: String) { bytes = sql.utf8; cursor = bytes.startIndex }
    private var current: UInt8? { cursor < bytes.endIndex ? bytes[cursor] : nil }
    private var following: UInt8? {
        guard cursor < bytes.endIndex else { return nil }
        let index = bytes.index(after: cursor)
        return index < bytes.endIndex ? bytes[index] : nil
    }
    private mutating func advance() throws {
        if visited & 4_095 == 0 { try Task.checkCancellation() }
        guard bytes[cursor] != 0 else { throw DirectSelectSyntaxError.unsupported }
        visited += 1; cursor = bytes.index(after: cursor)
    }
    private func startsIdentifier(_ byte: UInt8) -> Bool { byte == 95 || (65...90).contains(byte) || (97...122).contains(byte) || byte >= 128 }
    private func continuesIdentifier(_ byte: UInt8) -> Bool { startsIdentifier(byte) || (48...57).contains(byte) || byte == 36 }

    mutating func next() throws -> DirectSelectToken? {
        try Task.checkCancellation()
        while let byte = current {
            if byte == 32 || (9...13).contains(byte) { try advance(); continue }
            if byte == 45, following == 45 {
                try advance(); try advance()
                while let byte = current, byte != 10, byte != 13 { try advance() }
                continue
            }
            if byte == 47, following == 42 {
                try advance(); try advance()
                var depth = 1
                while let byte = current, depth > 0 {
                    if byte == 47, following == 42 { depth += 1; try advance(); try advance() }
                    else if byte == 42, following == 47 { depth -= 1; try advance(); try advance() }
                    else { try advance() }
                }
                guard depth == 0 else { throw DirectSelectSyntaxError.unsupported }
                continue
            }
            if byte == 39 { try quoted(quote: 39, escapes: false); return .literal }
            if byte == 34 { try quoted(quote: 34, escapes: false); return .identifier }
            if (byte == 69 || byte == 101), following == 39 {
                try advance(); try quoted(quote: 39, escapes: true); return .literal
            }
            if byte == 36, try dollarQuoted() { return .literal }
            if startsIdentifier(byte) {
                var word: [UInt8] = [], overlong = false
                while let byte = current, continuesIdentifier(byte) {
                    if word.count < 64 { word.append((97...122).contains(byte) ? byte - 32 : byte) }
                    else { overlong = true }
                    try advance()
                }
                return overlong ? .identifier : .word(String(decoding: word, as: UTF8.self))
            }
            if (48...57).contains(byte) {
                repeat { try advance() } while current.map { (48...57).contains($0) } == true
                return .literal
            }
            try advance(); return .symbol(byte)
        }
        return nil
    }

    private mutating func quoted(quote: UInt8, escapes: Bool) throws {
        try advance()
        while let byte = current {
            if byte == quote {
                try advance()
                if current == quote { try advance() } else { return }
            } else if quote == 39, byte == 92 {
                if escapes {
                    try advance()
                    guard current != nil else { throw DirectSelectSyntaxError.unsupported }
                    try advance()
                } else {
                    var count = 0
                    repeat { count += 1; try advance() } while current == 92
                    // Interpretation depends on standard_conforming_strings.
                    // Fail closed rather than misidentify a hidden FROM/JOIN.
                    if count % 2 == 1, current == 39 { throw DirectSelectSyntaxError.unsupported }
                }
            } else { try advance() }
        }
        throw DirectSelectSyntaxError.unsupported
    }

    private mutating func dollarQuoted() throws -> Bool {
        var end = bytes.index(after: cursor), tag: [UInt8] = [36]
        if end < bytes.endIndex, bytes[end] != 36 {
            guard startsIdentifier(bytes[end]) else { return false }
            while end < bytes.endIndex, bytes[end] != 36, continuesIdentifier(bytes[end]) {
                guard tag.count < 256 else { throw DirectSelectSyntaxError.unsupported }
                tag.append(bytes[end]); end = bytes.index(after: end)
            }
        }
        guard end < bytes.endIndex, bytes[end] == 36 else { return false }
        tag.append(36)
        for _ in tag { try advance() }
        while let byte = current {
            if byte == 36 {
                var candidate = cursor, matched = true
                for expected in tag {
                    guard candidate < bytes.endIndex, bytes[candidate] == expected else { matched = false; break }
                    candidate = bytes.index(after: candidate)
                }
                if matched { for _ in tag { try advance() }; return true }
            }
            try advance()
        }
        throw DirectSelectSyntaxError.unsupported
    }
}
