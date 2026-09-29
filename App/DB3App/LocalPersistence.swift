import Foundation
import Security
import DB3Core

/// All blocking persistence and credential operations are confined to this queue.
final class LocalPersistence: WorkbenchPersistence {
    private let queue = DispatchQueue(label: "app.db3.persistence", qos: .utility)
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }
    private static func directory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("db3", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    func loadProfiles() async throws -> [ConnectionProfile] {
        try await perform {
            let url = try Self.directory().appendingPathComponent("connections.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try JSONDecoder().decode([ConnectionProfile].self, from: Data(contentsOf: url))
        }
    }
    func saveProfiles(_ profiles: [ConnectionProfile]) async throws {
        try await perform {
            let data = try JSONEncoder().encode(profiles)
            let url = try Self.directory().appendingPathComponent("connections.json")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    func password(for id: UUID) async throws -> String {
        try await perform {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.db3.connection", kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return "" }
            guard status == errSecSuccess, let data = item as? Data else { throw DatabaseError("Keychain could not read this password (\(status)).") }
            return String(decoding: data, as: UTF8.self)
        }
    }
    func savePassword(_ password: String, for id: UUID) async throws {
        try await perform {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.db3.connection", kSecAttrAccount as String: id.uuidString]
            if password.isEmpty {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw DatabaseError("Keychain could not remove this password (\(status)).") }
                return
            }
            let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item.merge(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw DatabaseError("Keychain could not save this password (\(status)).") }
        }
    }
    func readSQL(at url: URL) async throws -> String { try await perform { try String(contentsOf: url, encoding: .utf8) } }
    func writeSQL(_ sql: String, at url: URL) async throws { try await perform { try sql.write(to: url, atomically: true, encoding: .utf8) } }
}

/// File identity can touch the filesystem (including network volumes). Keep it
/// off MainActor and off Swift's cooperative executor, with bounded concurrency.
final class SQLFileIdentityResolver: Sendable {
    static let shared = SQLFileIdentityResolver()
    private let queue = DispatchQueue(label: "app.db3.file-identity", qos: .utility)

    func resolve(_ url: URL) async -> URL {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: url.standardizedFileURL.resolvingSymlinksInPath())
            }
        }
    }
}
