import Foundation
import CryptoKit
import DB3Core

public enum ProjectConfigValue: Equatable, Sendable {
    case missing, empty, value(String), unresolved([String])
    public var string: String? { switch self { case .empty: ""; case .value(let text): text; default: nil } }
    public var isResolved: Bool { string != nil }
    public var status: String { switch self { case .missing: "Missing"; case .empty: "Empty"; case .value: "Present"; case .unresolved: "Unresolved" } }
    public static func resolved(_ text: String) -> Self { text.isEmpty ? .empty : .value(text) }
}

public struct ProjectConfigProvenance: Equatable, Sendable {
    public let relativePath: String
    public let line: Int
    public let key: String
    public init(relativePath: String, line: Int, key: String) { self.relativePath = relativePath; self.line = line; self.key = key }
}

public struct ProjectConfigDiagnostic: Equatable, Sendable, Identifiable {
    public let source: ProjectConfigProvenance
    /// Diagnostics are predefined explanations plus key names; never source values.
    public let message: String
    public var id: String { "\(source.relativePath):\(source.line):\(source.key):\(message)" }
    public init(source: ProjectConfigProvenance, message: String) { self.source = source; self.message = message }
}

public enum ProjectTLSReview: Equatable, Sendable {
    case missing, specified(TLSMode), unsupported(String), unresolved
    public var requiresReview: Bool { if case .specified(.verifyFull) = self { false } else { true } }
    public var explanation: String {
        switch self {
        case .missing: "No explicit TLS setting was found. Review verification before saving."
        case .specified(.verifyFull): "The source requests certificate and hostname verification."
        case .specified: "The source requests weaker TLS verification. Review it explicitly."
        case .unsupported: "The source TLS mode is not supported by db3. It has not been translated."
        case .unresolved: "The source TLS setting is unresolved."
        }
    }
}

public struct ProjectConnectionCandidate: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case postgresql, odooEvidence }
    public let id: String
    public let name: String
    public let kind: Kind
    public let sourceGroup: String
    public let environment: ConnectionEnvironment
    public let environmentEvidence: String
    public let host: ProjectConfigValue
    public let port: ProjectConfigValue
    public let database: ProjectConfigValue
    public let username: ProjectConfigValue
    /// Memory-only. Never include a candidate in JSON, diagnostic interpolation or logs.
    public let password: ProjectConfigValue
    public let rootCertificate: ProjectConfigValue
    public let tls: ProjectTLSReview
    public let provenance: [ProjectConfigProvenance]
    public let nonsecretFingerprint: String
    /// Process-keyed HMAC, comparable only during this application's lifetime.
    /// It detects credential changes without retaining raw .env or a reusable password hash.
    public let secretRevision: String
    public var hasUnresolvedRequirements: Bool {
        [host, database, username].contains { !$0.isResolved || $0 == .empty } || !portIsValid || {
            if case .unresolved = password { return true }; return false
        }()
    }
    public var portIsValid: Bool {
        if port == .missing { return true }
        guard let text = port.string, let value = Int(text), (1...65_535).contains(value) else { return false }
        return text.utf8.allSatisfy { (48...57).contains($0) }
    }
    public var reviewErrors: [String] {
        var errors: [String] = []
        for (label, value) in [("Host", host), ("Database", database), ("Username", username)] where !value.isResolved || value == .empty {
            errors.append(label + " is missing, empty, or unresolved.")
        }
        if !portIsValid { errors.append("Port must be between 1 and 65535.") }
        if case .unresolved = password { errors.append("Password is unresolved; enter it explicitly.") }
        if case .unresolved = rootCertificate { errors.append("CA certificate path is unresolved.") }
        if tls.requiresReview { errors.append(tls.explanation) }
        if kind == .odooEvidence { errors.append("Odoo application connections are deferred to task 08.") }
        return errors
    }
    public var reviewPassword: String { password.string ?? "" }
    /// A review form starts from verify-full regardless of weaker source evidence.
    /// Missing fields remain empty rather than inheriting the process user/host.
    public func reviewProfile(id: UUID = UUID()) -> ConnectionProfile {
        ConnectionProfile(id: id, name: name, host: host.string ?? "", port: Int(port.string ?? "") ?? 5432,
                          database: database.string ?? "", username: username.string ?? "", tls: .verifyFull,
                          rootCertificate: rootCertificate.string ?? "", environment: environment)
    }
}

public struct ProjectConfigurationSnapshot: Sendable {
    public let candidates: [ProjectConnectionCandidate]
    public let diagnostics: [ProjectConfigDiagnostic]
    public let revision: String
    public let evidence: [ProjectConfigEvidence]
    public let complete: Bool
}

public struct ProjectConfigEvidence: Equatable, Sendable {
    public enum Kind: String, Sendable { case odooPlaceholderConfiguration, tlsSetting, odooApplication }
    public let kind: Kind
    public let source: ProjectConfigProvenance
    /// A fixed classification such as "prefer", never an arbitrary source line.
    public let detail: String
}

public struct ProjectDotEnvEntry: Equatable, Sendable {
    public let value: ProjectConfigValue
    public let source: ProjectConfigProvenance
    /// Ephemeral process-keyed token, including unresolved literal changes.
    public let secretRevision: String
}
public struct ProjectDotEnvDocument: Sendable {
    public let entries: [String: ProjectDotEnvEntry]
    public let diagnostics: [ProjectConfigDiagnostic]
}

/// Literal .env subset: one assignment per line, optional export, single/double
/// quotes, whitespace comments, and $NAME/${NAME} from earlier allowed entries.
/// No shell, command substitution, defaults, forward-reference resolution or
/// inherited process environment. Unresolved text is not retained in snapshots.
public enum ProjectDotEnvParser {
    public static let maximumBytes = 2 * 1024 * 1024
    public static func parse(_ text: String, relativePath: String = ".env", allowedVariables: Set<String> = []) throws -> ProjectDotEnvDocument {
        guard text.utf8.count <= maximumBytes else { throw ProjectConfigurationError.fileTooLarge }
        var entries: [String: ProjectDotEnvEntry] = [:], diagnostics: [ProjectConfigDiagnostic] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, line) in lines.enumerated() {
            if offset & 255 == 0 { try Task.checkCancellation() }
            var body = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty || body.hasPrefix("#") { continue }
            if body.hasPrefix("export ") || body.hasPrefix("export\t") { body = String(body.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = body.firstIndex(of: "=") else { continue }
            let key = body[..<equals].trimmingCharacters(in: .whitespaces)
            guard validKey(key) else { continue }
            let source = ProjectConfigProvenance(relativePath: relativePath, line: offset + 1, key: key)
            guard entries.count < 4096 || entries[key] != nil else {
                diagnostics.append(.init(source: source, message: "The configuration entry limit was reached.")); break
            }
            let raw = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let parsed: ProjectConfigValue
            if raw.utf8.count > 64 * 1024 || raw.utf8.contains(0) { parsed = .unresolved(["unsupported value size or encoding"]) }
            else {
                do { parsed = try parseValue(raw, entries: entries, allowed: allowedVariables) }
                catch { parsed = .unresolved(["unsupported literal syntax"]) }
            }
            if case .unresolved = parsed { diagnostics.append(.init(source: source, message: "This value is unresolved. Review its references or literal syntax.")) }
            if entries[key] != nil { diagnostics.append(.init(source: source, message: "This key is repeated; its last definition is used.")) }
            entries[key] = ProjectDotEnvEntry(value: parsed, source: source,
                secretRevision: ProjectFingerprint.secret(parsed.isResolved ? parsed : .value(raw)))
        }
        return ProjectDotEnvDocument(entries: entries, diagnostics: Array(diagnostics.prefix(512)))
    }

    public static func validKey(_ key: String) -> Bool {
        guard let first = key.utf8.first, first == 95 || (65...90).contains(first) || (97...122).contains(first), key.utf8.count <= 128 else { return false }
        return key.utf8.allSatisfy { $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }

    private static func parseValue(_ raw: String, entries: [String: ProjectDotEnvEntry], allowed: Set<String>) throws -> ProjectConfigValue {
        guard let quote = raw.first, quote == "'" || quote == "\"" else {
            var literal = raw
            if let hash = raw.indices.first(where: { raw[$0] == "#" && ($0 == raw.startIndex || raw[raw.index(before: $0)].isWhitespace) }) {
                literal = String(raw[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            return interpolate(literal, entries: entries, allowed: allowed)
        }
        var result = "", index = raw.index(after: raw.startIndex), closed = false
        while index < raw.endIndex {
            let char = raw[index]; index = raw.index(after: index)
            if char == quote { closed = true; break }
            if quote == "\"", char == "\\" {
                guard index < raw.endIndex else { throw ProjectConfigurationError.invalidLiteral }
                let escaped = raw[index]; index = raw.index(after: index)
                switch escaped {
                case "n": result += "\n"
                case "r": result += "\r"
                case "t": result += "\t"
                case "\"", "\\": result.append(escaped)
                case "$": result += "\u{1}" // Protected dollar, restored after interpolation.
                default: result += "\\"; result.append(escaped)
                }
            } else { result.append(char) }
        }
        let tail = raw[index...].trimmingCharacters(in: .whitespaces)
        guard closed, tail.isEmpty || tail.hasPrefix("#"), !raw.contains("\u{1}") else { throw ProjectConfigurationError.invalidLiteral }
        if quote == "'" { return .resolved(result) }
        let expanded = interpolate(result, entries: entries, allowed: allowed)
        if let value = expanded.string { return .resolved(value.replacingOccurrences(of: "\u{1}", with: "$")) }
        return expanded
    }

    private static func interpolate(_ text: String, entries: [String: ProjectDotEnvEntry], allowed: Set<String>) -> ProjectConfigValue {
        var result = "", index = text.startIndex, count = 0, unresolved: [String] = []
        while index < text.endIndex {
            let char = text[index]; index = text.index(after: index)
            guard char == "$" else { result.append(char); continue }
            guard index < text.endIndex else { result.append("$"); break }
            count += 1
            guard count <= 128 else { return .unresolved(["interpolation limit"]) }
            let key: String
            if text[index] == "{" {
                let start = text.index(after: index)
                guard let end = text[start...].firstIndex(of: "}") else { return .unresolved(["unfinished interpolation"]) }
                key = String(text[start..<end]); index = text.index(after: end)
            } else if text[index] == "(" || text[index] == "`" { return .unresolved(["command expressions are not evaluated"]) }
            else {
                let start = index
                while index < text.endIndex, text[index].isASCII,
                      text[index].isLetter || text[index].isNumber || text[index] == "_" { index = text.index(after: index) }
                key = String(text[start..<index])
                if key.isEmpty { result.append("$"); continue }
            }
            guard validKey(key), allowed.contains(key), let value = entries[key]?.value.string else {
                unresolved.append(validKey(key) ? key : "unsupported interpolation"); continue
            }
            guard result.utf8.count + value.utf8.count <= 64 * 1024 else { return .unresolved(["expanded value limit"]) }
            result += value
        }
        return unresolved.isEmpty ? .resolved(result) : .unresolved(Array(Set(unresolved)).sorted())
    }
}

public enum ProjectConfigurationError: Error, LocalizedError, Sendable {
    case fileTooLarge, invalidLiteral, unavailable
    public var errorDescription: String? {
        switch self { case .fileTooLarge: "A project configuration file exceeds the 2 MiB limit."; case .invalidLiteral: "A project configuration value uses unsupported literal syntax."; case .unavailable: "A project configuration file is unavailable or is not a regular file." }
    }
}

enum ProjectFingerprint {
    static let key = SymmetricKey(size: .bits256)
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ strings: [String]) -> String { digest(Data(strings.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)) }
    static func secret(_ value: ProjectConfigValue) -> String {
        let bytes = Data((value.string.map { "resolved:\($0)" } ?? value.status).utf8)
        return HMAC<SHA256>.authenticationCode(for: bytes, using: key).map { String(format: "%02x", $0) }.joined()
    }
}
