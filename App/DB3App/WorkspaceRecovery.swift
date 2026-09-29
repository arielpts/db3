import Foundation
import Darwin
import DB3Core

/// A recovery document contains editor state only. Credentials, result pages,
/// database sessions, and transactions never enter this persistence boundary.
struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumTabs = 4
    static let maximumBytes = 64 * 1_024 * 1_024

    let version: Int
    let tabs: [WorkspaceTabSnapshot]
    let selectedTabIndex: Int
    let selectedBrowserProfileID: UUID?
    let showingInspector: Bool
    let nextUntitledNumber: Int

    init(version: Int = Self.currentVersion, tabs: [WorkspaceTabSnapshot], selectedTabIndex: Int = 0,
         selectedBrowserProfileID: UUID? = nil, showingInspector: Bool = false, nextUntitledNumber: Int = 2) {
        self.version = version; self.tabs = tabs; self.selectedTabIndex = selectedTabIndex
        self.selectedBrowserProfileID = selectedBrowserProfileID; self.showingInspector = showingInspector
        self.nextUntitledNumber = nextUntitledNumber
    }
}

struct WorkspaceTabSnapshot: Codable, Equatable, Sendable {
    let title: String
    let sql: String
    let savedSQL: String
    let fileURL: URL?
    let selectionLocation: Int
    let selectionLength: Int
    let profile: ConnectionProfile?
    let database: String?
    let schema: String?
    let object: String?
    let allowsSpooling: Bool
    let resultTab: Int
    let isDemo: Bool

    init(title: String, sql: String, savedSQL: String, fileURL: URL? = nil,
         selectionLocation: Int = 0, selectionLength: Int = 0, profile: ConnectionProfile? = nil,
         database: String? = nil, schema: String? = nil, object: String? = nil,
         allowsSpooling: Bool = true, resultTab: Int = 0, isDemo: Bool = false) {
        self.title = title; self.sql = sql; self.savedSQL = savedSQL; self.fileURL = fileURL
        self.selectionLocation = selectionLocation; self.selectionLength = selectionLength
        self.profile = profile; self.database = database; self.schema = schema; self.object = object
        self.allowsSpooling = allowsSpooling; self.resultTab = resultTab
        self.isDemo = isDemo
    }
}

protocol WorkspaceRecoveryPersistence: Sendable {
    func loadWorkspace() async throws -> WorkspaceSnapshot?
    func saveWorkspace(_ snapshot: WorkspaceSnapshot) async throws
}

enum WorkspaceRecoveryError: Error, LocalizedError {
    case invalid(String)
    case unsupportedVersion(Int)
    case tooLarge
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): "The saved workspace is invalid: \(detail)"
        case .unsupportedVersion(let version): "Workspace version \(version) is not supported by this version of db3."
        case .tooLarge: "The workspace exceeds the 64 MiB recovery limit. Its SQL has not been truncated or saved."
        case .io(let message): message
        }
    }
}

/// Uses a dedicated blocking-I/O queue, including JSON and Unicode validation.
/// Atomic replacement keeps the old recovery file intact until the new private
/// file has been completely written and flushed.
final class LocalWorkspaceRecoveryStore: WorkspaceRecoveryPersistence {
    private let queue = DispatchQueue(label: "app.db3.workspace-recovery", qos: .utility)
    private let customURL: URL?

    init(url: URL? = nil) { customURL = url }
    convenience init(customURL: URL) { self.init(url: customURL) }

    func loadWorkspace() async throws -> WorkspaceSnapshot? {
        try await perform { [customURL] in
            let url = try Self.destination(customURL)
            guard let data = try Self.readBoundedFile(at: url) else { return nil }
            return try Self.decodeWorkspace(data)
        }
    }

    func saveWorkspace(_ snapshot: WorkspaceSnapshot) async throws {
        try await perform { [customURL] in
            try WorkspaceRecoveryValidation.validate(snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(snapshot)
            guard data.count <= WorkspaceSnapshot.maximumBytes else { throw WorkspaceRecoveryError.tooLarge }
            try Self.replaceAtomically(data, at: Self.destination(customURL))
        }
    }

    private func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    private static func destination(_ customURL: URL?) throws -> URL {
        if let customURL {
            guard customURL.isFileURL, customURL.path.hasPrefix("/"), !customURL.lastPathComponent.isEmpty else {
                throw WorkspaceRecoveryError.invalid("the recovery destination must be a local file URL.")
            }
            return customURL
        }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("db3", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }

    private static func decodeWorkspace(_ data: Data) throws -> WorkspaceSnapshot {
        let snapshot: WorkspaceSnapshot
        do { snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data) }
        catch { throw WorkspaceRecoveryError.invalid("the recovery document could not be decoded.") }
        try WorkspaceRecoveryValidation.validate(snapshot)
        return snapshot
    }

    private static func readBoundedFile(at url: URL) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw systemError("The saved workspace could not be opened")
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw systemError("The saved workspace could not be inspected") }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw WorkspaceRecoveryError.invalid("the recovery document is not a regular file.")
        }
        guard information.st_size >= 0, information.st_size <= WorkspaceSnapshot.maximumBytes else {
            throw WorkspaceRecoveryError.tooLarge
        }
        var result = Data(capacity: Int(information.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("The saved workspace could not be read")
            }
            if count == 0 { break }
            guard result.count <= WorkspaceSnapshot.maximumBytes - count else { throw WorkspaceRecoveryError.tooLarge }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func replaceAtomically(_ data: Data, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".workspace-\(UUID().uuidString).tmp")
        // Mode is private at creation; there is no world-readable intermediate
        // file before a later chmod, including when an existing file is replaced.
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw systemError("The workspace recovery file could not be created") }
        defer { Darwin.close(descriptor); Darwin.unlink(temporary.path) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw systemError("The workspace recovery file could not be protected") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw systemError("The workspace recovery file could not be written")
                }
                guard written > 0 else { throw WorkspaceRecoveryError.io("Writing the workspace recovery file made no progress.") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw systemError("The workspace recovery file could not be flushed") }
        try preserveUnreadableWorkspace(at: url)
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw systemError("The saved workspace could not be replaced") }
    }

    /// Preserve unreadable or future-version data before saving current drafts.
    /// A hard link preserves the original bytes without reading/copying a file
    /// whose size may exceed the decoder's bounded envelope.
    private static func preserveUnreadableWorkspace(at url: URL) throws {
        var original = stat()
        guard lstat(url.path, &original) == 0 else {
            if errno == ENOENT { return }
            throw systemError("The existing workspace could not be inspected")
        }
        guard original.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw WorkspaceRecoveryError.invalid("the existing recovery document is not a regular file; it was left unchanged.")
        }
        do {
            guard let data = try readBoundedFile(at: url) else {
                throw WorkspaceRecoveryError.io("The existing workspace changed during saving. Try again.")
            }
            _ = try decodeWorkspace(data)
            return
        } catch let error as WorkspaceRecoveryError {
            switch error {
            case .invalid, .unsupportedVersion, .tooLarge: break
            case .io: throw error
            }
        }

        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("workspace-unreadable-\(UUID().uuidString).json")
        // link() refuses an existing destination; backups are never overwritten.
        guard Darwin.link(url.path, backup.path) == 0 else {
            throw systemError("The unreadable workspace could not be backed up; the previous file was kept")
        }
        var keepBackup = false
        defer { if !keepBackup { Darwin.unlink(backup.path) } }
        let descriptor = Darwin.open(backup.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw systemError("The workspace backup could not be verified") }
        defer { Darwin.close(descriptor) }
        var linked = stat()
        guard fstat(descriptor, &linked) == 0 else { throw systemError("The workspace backup could not be inspected") }
        guard linked.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              linked.st_dev == original.st_dev, linked.st_ino == original.st_ino else {
            throw WorkspaceRecoveryError.io("The existing workspace changed during backup. Its replacement was cancelled.")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw systemError("The workspace backup could not be protected") }
        keepBackup = true
    }

    private static func systemError(_ action: String) -> WorkspaceRecoveryError {
        let code = errno
        return .io("\(action): \(String(cString: strerror(code))).")
    }
}

/// Tests or nonlocal persistence providers can use memory without reading or
/// writing the real user's recovery file. The same validation applies.
actor MemoryWorkspaceRecoveryStore: WorkspaceRecoveryPersistence {
    private var snapshot: WorkspaceSnapshot?
    init(snapshot: WorkspaceSnapshot? = nil) { self.snapshot = snapshot }
    func loadWorkspace() async throws -> WorkspaceSnapshot? {
        if let snapshot { try WorkspaceRecoveryValidation.validate(snapshot) }
        return snapshot
    }
    func saveWorkspace(_ snapshot: WorkspaceSnapshot) async throws {
        try WorkspaceRecoveryValidation.validate(snapshot)
        self.snapshot = snapshot
    }
}

extension LocalPersistence: WorkspaceRecoveryPersistence {
    private static let workspaceRecoveryStore = LocalWorkspaceRecoveryStore()
    func loadWorkspace() async throws -> WorkspaceSnapshot? { try await Self.workspaceRecoveryStore.loadWorkspace() }
    func saveWorkspace(_ snapshot: WorkspaceSnapshot) async throws { try await Self.workspaceRecoveryStore.saveWorkspace(snapshot) }
}

private enum WorkspaceRecoveryValidation {
    static func validate(_ snapshot: WorkspaceSnapshot) throws {
        guard snapshot.version == WorkspaceSnapshot.currentVersion else { throw WorkspaceRecoveryError.unsupportedVersion(snapshot.version) }
        guard snapshot.tabs.count <= WorkspaceSnapshot.maximumTabs else { throw WorkspaceRecoveryError.invalid("a workspace can contain at most four query tabs.") }
        guard snapshot.selectedTabIndex >= 0,
              snapshot.tabs.isEmpty ? snapshot.selectedTabIndex == 0 : snapshot.selectedTabIndex < snapshot.tabs.count else {
            throw WorkspaceRecoveryError.invalid("the selected query tab is out of range.")
        }
        guard snapshot.nextUntitledNumber > 0, snapshot.nextUntitledNumber <= Int.max - WorkspaceSnapshot.maximumTabs else {
            throw WorkspaceRecoveryError.invalid("the next query number is out of range.")
        }
        // A conservative preflight bounds encoding allocations even for SQL
        // containing many control characters requiring JSON escaping.
        var budget = WorkspaceSnapshot.maximumBytes - 512
        for tab in snapshot.tabs {
            budget -= 1_024
            try consume(tab.title, budget: &budget)
            try consume(tab.sql, budget: &budget)
            try consume(tab.savedSQL, budget: &budget)
            for value in [tab.fileURL?.absoluteString, tab.database, tab.schema, tab.object].compactMap({ $0 }) {
                try consume(value, budget: &budget)
            }
            if let profile = tab.profile {
                for value in [profile.name, profile.host, profile.database, profile.username, profile.rootCertificate] {
                    try consume(value, budget: &budget)
                }
                guard (1...65_535).contains(profile.port) else { throw WorkspaceRecoveryError.invalid("a saved connection port is out of range.") }
            }
            guard budget >= 0 else { throw WorkspaceRecoveryError.tooLarge }
            if let fileURL = tab.fileURL, !fileURL.isFileURL || !fileURL.path.hasPrefix("/") {
                throw WorkspaceRecoveryError.invalid("a query file reference is not a local file URL.")
            }
            guard (0...1).contains(tab.resultTab) else { throw WorkspaceRecoveryError.invalid("a result pane selection is out of range.") }
            let length = tab.sql.utf16.count
            guard tab.selectionLocation >= 0, tab.selectionLength >= 0,
                  tab.selectionLocation <= length, tab.selectionLength <= length - tab.selectionLocation else {
                throw WorkspaceRecoveryError.invalid("a query cursor or selection is outside its SQL text.")
            }
            let utf16 = tab.sql.utf16
            let start = utf16.index(utf16.startIndex, offsetBy: tab.selectionLocation)
            let end = utf16.index(start, offsetBy: tab.selectionLength)
            guard String.Index(start, within: tab.sql) != nil, String.Index(end, within: tab.sql) != nil else {
                throw WorkspaceRecoveryError.invalid("a query selection splits a Unicode character.")
            }
        }
    }

    private static func consume(_ string: String, budget: inout Int) throws {
        for byte in string.utf8 {
            switch byte {
            case 0...31: budget -= 6
            case 34, 92: budget -= 2
            default: budget -= 1
            }
            if budget < 0 { throw WorkspaceRecoveryError.tooLarge }
        }
    }
}
