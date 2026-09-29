import Foundation

/// Classifies only the leading, unquoted PostgreSQL keywords of a statement.
/// Strings, quoted identifiers, dollar bodies and punctuation stop the prefix;
/// keywords inside them can never turn ordinary SQL into transaction control.
/// This does not split scripts. The extended-query driver enforces one statement.
public enum SQLTransactionControl: Equatable, Sendable {
    case ordinary, begin, commit, rollback, rollbackToSavepoint
    case savepoint, releaseSavepoint, setTransaction, unsupported

    public var endsTransaction: Bool { self == .commit || self == .rollback }

    public static func classify(_ sql: String) throws -> Self {
        classify(try leadingKeywords(sql))
    }

    static func classify(_ words: [String]) -> Self {
        guard let first = words.first else { return .ordinary }
        let second = words.count > 1 ? words[1] : ""
        switch first {
        case "BEGIN": return .begin
        case "START": return second == "TRANSACTION" ? .begin : .ordinary
        case "COMMIT", "END": return second == "PREPARED" ? .unsupported : .commit
        case "ROLLBACK", "ABORT":
            if second == "PREPARED" { return .unsupported }
            let tail = words.dropFirst().drop(while: { $0 == "WORK" || $0 == "TRANSACTION" })
            return tail.first == "TO" ? .rollbackToSavepoint : .rollback
        case "SAVEPOINT": return .savepoint
        case "RELEASE": return .releaseSavepoint
        case "PREPARE": return second == "TRANSACTION" ? .unsupported : .ordinary
        case "SET":
            let tail = Array(words.dropFirst())
            if tail.first == "TRANSACTION" || tail.starts(with: ["LOCAL", "TRANSACTION"]) ||
                tail.starts(with: ["SESSION", "TRANSACTION"]) ||
                tail.starts(with: ["SESSION", "CHARACTERISTICS", "AS", "TRANSACTION"]) { return .setTransaction }
            return .ordinary
        default: return .ordinary
        }
    }

    /// Bounded keyword storage, with no copy of the SQL document. Comments can
    /// be arbitrarily long and nested, so scanning remains cancellation-aware.
    static func leadingKeywords(_ sql: String) throws -> [String] {
        let bytes = sql.utf8
        var cursor = bytes.startIndex, visited = 0, words: [String] = []
        func next(_ index: String.UTF8View.Index) -> String.UTF8View.Index { bytes.index(after: index) }
        func followingByte(after index: String.UTF8View.Index) -> UInt8? {
            let following = next(index)
            return following < bytes.endIndex ? bytes[following] : nil
        }
        func wordByte(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 36 || byte >= 128
        }
        func checkpoint() throws {
            visited += 1
            if visited & 4_095 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        while cursor < bytes.endIndex, words.count < 6 {
            try checkpoint()
            let byte = bytes[cursor]
            if byte == 32 || (9...13).contains(byte) { cursor = next(cursor); continue }
            // libpq accepts leading empty statements with one real command.
            // They must not hide a control from draft/transaction guards.
            if byte == 59, words.isEmpty { cursor = next(cursor); continue }
            if byte == 45, followingByte(after: cursor) == 45 {
                cursor = next(next(cursor))
                while cursor < bytes.endIndex, bytes[cursor] != 10, bytes[cursor] != 13 { try checkpoint(); cursor = next(cursor) }
                continue
            }
            if byte == 47, followingByte(after: cursor) == 42 {
                cursor = next(next(cursor))
                var depth = 1
                while cursor < bytes.endIndex, depth > 0 {
                    try checkpoint()
                    if bytes[cursor] == 47, followingByte(after: cursor) == 42 { depth += 1; cursor = next(next(cursor)) }
                    else if bytes[cursor] == 42, followingByte(after: cursor) == 47 { depth -= 1; cursor = next(next(cursor)) }
                    else { cursor = next(cursor) }
                }
                guard depth == 0 else { throw DatabaseError("Close the unfinished SQL block comment before running this statement.") }
                continue
            }
            guard wordByte(byte), byte != 36, !(48...57).contains(byte) else { break }
            var word: [UInt8] = []
            while cursor < bytes.endIndex, wordByte(bytes[cursor]) {
                try checkpoint()
                // An overlong identifier cannot be a transaction keyword.
                guard word.count < 64 else { return words + [""] }
                let current = bytes[cursor]
                word.append((97...122).contains(current) ? current - 32 : current)
                cursor = next(cursor)
            }
            words.append(String(decoding: word, as: UTF8.self))
        }
        return words
    }
}
