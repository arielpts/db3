import Foundation
import Darwin

public struct ProjectRecent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data
    public var rootIdentity: String
    public var lastOpened: Date
    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data, rootIdentity: String, lastOpened: Date = Date()) {
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark; self.rootIdentity = rootIdentity; self.lastOpened = lastOpened
    }
}
public struct ProjectFolderResolution: Sendable {
    public let url: URL
    public let bookmarkStale: Bool
}
public struct ProjectPrivateObjectAnchor: Codable, Hashable, Sendable {
    public var schema: String
    public var relation: String
    public var databaseOID: UInt32
    public var schemaOID: UInt32
    public var relationOID: UInt32
    public var identityToken: String
    public init(schema: String, relation: String, databaseOID: UInt32, schemaOID: UInt32, relationOID: UInt32, identityToken: String) {
        self.schema = schema; self.relation = relation; self.databaseOID = databaseOID
        self.schemaOID = schemaOID; self.relationOID = relationOID; self.identityToken = identityToken
    }
}
public struct ProjectPrivateBinding: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var endpointFingerprint: String
    public var schema: String
    public var candidateID: String?
    public var candidateFingerprint: String?
    public var databaseOID: UInt32?
    public var objects: [ProjectPrivateObjectAnchor]
    public init(profileID: UUID, endpointFingerprint: String, schema: String = "public", candidateID: String? = nil,
                candidateFingerprint: String? = nil, databaseOID: UInt32? = nil, objects: [ProjectPrivateObjectAnchor] = []) {
        self.profileID = profileID; self.endpointFingerprint = endpointFingerprint; self.schema = schema
        self.candidateID = candidateID; self.candidateFingerprint = candidateFingerprint; self.databaseOID = databaseOID; self.objects = objects
    }
}
public struct ProjectPrivateState: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var recents: [ProjectRecent] = []
    /// Project UUID string -> portable logical binding key -> private target.
    public var bindings: [String: [String: ProjectPrivateBinding]] = [:]
    public var activeProjectID: UUID?
    public init() { }
}

/// Device-specific bookmarks, saved profile references and catalog anchors only.
/// This schema deliberately has no password, raw dotenv or secret-digest field.
public actor ProjectPrivateStore {
    public nonisolated let fileURL: URL
    private let directory: URL
    private var cached: ProjectPrivateState?
    public init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("db3", isDirectory: true)
        self.directory = directory; fileURL = directory.appendingPathComponent("projects.json")
    }
    public func load() throws -> ProjectPrivateState {
        if let cached { return cached }
        guard let bytes = try ProjectFileIO.readIfPresent(fileURL, maximumBytes: 2 * 1024 * 1024) else {
            let state = ProjectPrivateState(); cached = state; return state
        }
        let state: ProjectPrivateState
        do { state = try JSONDecoder().decode(ProjectPrivateState.self, from: bytes) }
        catch { throw ProjectSettingsError.invalidFormat }
        guard state.version == 1, state.recents.count <= 20, state.bindings.count <= 100 else { throw ProjectSettingsError.invalidFormat }
        cached = state; return state
    }
    @discardableResult public func remember(root: URL, replacing projectID: UUID? = nil) throws -> ProjectRecent {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ProjectSettingsError.unavailable }
        let bookmark: Data
        do { bookmark = try canonical.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { throw ProjectSettingsError.unavailable }
        var state = try load()
        let identity = ProjectFingerprint.digest([canonical.path])
        if let projectID, !state.recents.contains(where: { $0.id == projectID }) { throw ProjectSettingsError.invalidFormat }
        let previous = state.recents.first { projectID != nil ? $0.id == projectID : $0.rootIdentity == identity }
        let recent = ProjectRecent(id: previous?.id ?? UUID(), name: canonical.lastPathComponent, path: canonical.path,
                                   bookmark: bookmark, rootIdentity: identity)
        state.recents.removeAll { $0.id == recent.id }; state.recents.insert(recent, at: 0)
        state.recents = Array(state.recents.prefix(20)); state.activeProjectID = recent.id
        try persist(state); return recent
    }
    public func resolve(_ recent: ProjectRecent) throws -> ProjectFolderResolution {
        var stale = false
        let url: URL
        do { url = try URL(resolvingBookmarkData: recent.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { throw ProjectSettingsError.unavailable }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ProjectSettingsError.unavailable }
        return ProjectFolderResolution(url: url, bookmarkStale: stale)
    }
    public func setActiveProject(_ id: UUID?) throws {
        var state = try load()
        guard id == nil || state.recents.contains(where: { $0.id == id }) else { throw ProjectSettingsError.invalidFormat }
        state.activeProjectID = id; try persist(state)
    }
    public func bind(projectID: UUID, key: String, binding: ProjectPrivateBinding?) throws {
        guard ProjectSettingsStore.logicalKey(key) else { throw ProjectSettingsError.invalidFormat }
        var state = try load()
        guard state.recents.contains(where: { $0.id == projectID }) else { throw ProjectSettingsError.invalidFormat }
        if let binding {
            guard binding.objects.count <= 10_000, binding.endpointFingerprint.utf8.count <= 256,
                  (binding.candidateFingerprint?.utf8.count ?? 0) <= 256 else { throw ProjectSettingsError.tooLarge }
            state.bindings[projectID.uuidString, default: [:]][key] = binding
        } else { state.bindings[projectID.uuidString]?[key] = nil }
        try persist(state)
    }
    private func persist(_ state: ProjectPrivateState) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw ProjectSettingsError.unavailable }
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ProjectSettingsError.unavailable }
        guard chmod(directory.path, 0o700) == 0 else { throw ProjectSettingsError.unavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        guard bytes.count <= 2 * 1024 * 1024 else { throw ProjectSettingsError.tooLarge }
        try ProjectAtomicFile.write(bytes, to: fileURL, permissions: 0o600)
        cached = state
    }
}
