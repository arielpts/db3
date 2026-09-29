import Foundation
import CryptoKit

/// Keys are PostgreSQL text-protocol values, never display labels or runtime
/// booleans. SQL NULL is a separate editor action and is not a choice key.
public struct ValueChoice: Hashable, Sendable {
    public let key: String
    public let label: String
    public let description: String?
    public let color: String?
    public let icon: String?
    public let shortLabel: String?
    public init(key: String, label: String, description: String? = nil, color: String? = nil,
                icon: String? = nil, shortLabel: String? = nil) {
        self.key = key; self.label = label; self.description = description
        self.color = color; self.icon = icon; self.shortLabel = shortLabel
    }
}

/// Immutable, complete vocabulary captured with the editable table metadata.
/// Unresolved sets intentionally contain no partial choices.
public struct ValueChoiceSet: Hashable, Sendable {
    public enum Origin: Hashable, Sendable { case project, postgresEnum(typeOID: UInt32) }
    public enum Status: Hashable, Sendable { case resolved, unresolved(String) }
    public static let maximumChoices = 10_000
    public static let maximumBytes = 2 * 1_024 * 1_024
    public let choices: [ValueChoice]
    public let source: String
    public let revision: String
    public let origin: Origin
    public let status: Status
    public let fingerprint: String
    public let byteCount: Int
    private let keys: Set<Data>
    private let maximumKeyBytes: Int

    public init(choices: [ValueChoice], source: String, revision: String,
                origin: Origin = .project, status: Status = .resolved) throws {
        guard choices.count <= Self.maximumChoices else { throw DatabaseError("This choice vocabulary exceeds the 10,000-value limit.") }
        if case .unresolved = status, !choices.isEmpty { throw DatabaseError("Unresolved choices must not present a partial vocabulary as complete.") }
        var keys = Set<Data>()
        var bytes = 0
        var maximumKeyBytes = 0
        var digest = SHA256()
        func include(_ field: String) throws {
            bytes += field.utf8.count + 64
            guard bytes <= Self.maximumBytes else { throw DatabaseError("This choice vocabulary exceeds the 2 MiB metadata limit.") }
            digest.update(data: Data("\(field.utf8.count):".utf8)); digest.update(data: Data(field.utf8))
        }
        for field in [source, revision, String(describing: origin), String(describing: status)] { try include(field) }
        for choice in choices {
            // Account the byte-key lookup index before allocating its storage.
            bytes += choice.key.utf8.count
            maximumKeyBytes = max(maximumKeyBytes, choice.key.utf8.count)
            for field in [choice.key, choice.label, choice.description ?? "", choice.color ?? "", choice.icon ?? "", choice.shortLabel ?? ""] { try include(field) }
            guard !choice.key.utf8.contains(0), keys.insert(Data(choice.key.utf8)).inserted else { throw DatabaseError("Choice keys must be unique and contain no NUL characters.") }
        }
        self.choices = choices; self.source = source; self.revision = revision
        self.origin = origin; self.status = status; self.keys = keys; self.byteCount = bytes
        self.maximumKeyBytes = maximumKeyBytes
        fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public var isResolved: Bool { status == .resolved }
    public var isAuthoritative: Bool { if case .postgresEnum = origin { true } else { false } }
    public func contains(key: String) -> Bool { key.utf8.count <= maximumKeyBytes && keys.contains(Data(key.utf8)) }
    public var statusText: String {
        switch status {
        case .resolved: source
        case .unresolved(let reason): "\(source) · Choices unavailable: \(reason)"
        }
    }

    /// Call away from the main actor. Search visits the complete bounded set,
    /// while returning at most 200 virtualized rows and an accurate match count.
    public func search(_ query: String, limit: Int = 200) throws -> ValueChoiceSearchResult {
        guard query.utf8.prefix(4_097).count <= 4_096 else { throw DatabaseError("Choice searches are limited to 4,096 bytes.") }
        let limit = min(200, max(1, limit))
        var matches: [Int] = [], total = 0
        for (index, choice) in choices.enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            if query.isEmpty || [choice.key, choice.label, choice.description ?? ""].contains(where: {
                $0.range(of: query, options: [.caseInsensitive, .literal], locale: Locale(identifier: "en_US_POSIX")) != nil
            }) {
                total += 1
                if matches.count < limit { matches.append(index) }
            }
        }
        return ValueChoiceSearchResult(indices: matches, totalMatches: total)
    }
}

public struct ValueChoiceSearchResult: Hashable, Sendable {
    public let indices: [Int]
    public let totalMatches: Int
    public var isLimited: Bool { totalMatches > indices.count }
}
