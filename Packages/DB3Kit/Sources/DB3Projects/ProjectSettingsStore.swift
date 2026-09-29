import Foundation
import Darwin

public struct ProjectNamespaceSettings: Codable, Equatable, Sendable {
    public var showBase: Bool
    public var order: [String]
    public var displayNames: [String: String]
    public init(showBase: Bool = false, order: [String] = [], displayNames: [String: String] = [:]) {
        self.showBase = showBase; self.order = order; self.displayNames = displayNames
    }
}
public struct ProjectLogicalBinding: Codable, Equatable, Sendable {
    public var sourceGroup: String
    public init(sourceGroup: String) { self.sourceGroup = sourceGroup }
}
public struct ProjectObjectOverride: Codable, Hashable, Sendable, Identifiable {
    public var binding: String
    public var schema: String
    public var relation: String
    public var namespace: String
    public var id: String { ProjectFingerprint.digest([binding, schema, relation]) }
    public init(binding: String, schema: String, relation: String, namespace: String) {
        self.binding = binding; self.schema = schema; self.relation = relation; self.namespace = namespace
    }
}
public struct ProjectSettings: Codable, Equatable, Sendable {
    public var version: Int
    public var adapter: String?
    public var namespaces: ProjectNamespaceSettings
    public var bindings: [String: ProjectLogicalBinding]
    public var objectOverrides: [ProjectObjectOverride]
    public init(version: Int = 1, adapter: String? = nil, namespaces: ProjectNamespaceSettings = .init(),
                bindings: [String: ProjectLogicalBinding] = [:], objectOverrides: [ProjectObjectOverride] = []) {
        self.version = version; self.adapter = adapter; self.namespaces = namespaces; self.bindings = bindings; self.objectOverrides = objectOverrides
    }
}
public struct ProjectSettingsDocument: Sendable {
    public var settings: ProjectSettings
    public let digest: String?
    fileprivate let original: [String: ProjectJSONValue]
    public init(settings: ProjectSettings = .init()) { self.settings = settings; digest = nil; original = [:] }
    fileprivate init(settings: ProjectSettings, digest: String?, original: [String: ProjectJSONValue]) {
        self.settings = settings; self.digest = digest; self.original = original
    }
}
public enum ProjectSettingsError: Error, LocalizedError, Equatable, Sendable {
    case conflict, unsupportedVersion(Int), invalidFormat, readOnly, unavailable, tooLarge
    public var errorDescription: String? {
        switch self {
        case .conflict: "Project settings changed in another application. Reload or merge before retrying; your changes were not saved."
        case .unsupportedVersion: "This project settings version is newer than db3 supports."
        case .invalidFormat: "Project settings are invalid. Correct the file or reload it before saving."
        case .readOnly: "Changes not saved: the project settings folder is read-only. Retry after fixing access or revert your changes."
        case .unavailable: "Project settings are unavailable or use an unsafe filesystem path."
        case .tooLarge: "Project settings exceed the 2 MiB size limit."
        }
    }
}

/// Versioned portable settings only. Endpoints, passwords, machine bookmarks,
/// saved-profile UUIDs and transient database identities belong in private state.
public actor ProjectSettingsStore {
    public nonisolated let fileURL: URL
    private let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL; fileURL = root.appendingPathComponent(".db3/project.json") }

    public func load() throws -> ProjectSettingsDocument {
        try ensureDirectory(create: false)
        let bytes: Data?
        do { bytes = try ProjectFileIO.readIfPresent(fileURL, maximumBytes: 2 * 1024 * 1024) }
        catch ProjectConfigurationError.fileTooLarge { throw ProjectSettingsError.tooLarge }
        catch { throw ProjectSettingsError.unavailable }
        guard let bytes else { return ProjectSettingsDocument() }
        return try Self.decode(bytes)
    }

    public func save(_ document: ProjectSettingsDocument) throws -> ProjectSettingsDocument { try save(document, expectedDigest: document.digest) }
    public func save(_ document: ProjectSettingsDocument, expectedDigest: String?) throws -> ProjectSettingsDocument {
        try Self.validate(document.settings)
        try ensureDirectory(create: true)
        let bytes = try Self.encode(document)
        guard bytes.count <= 2 * 1024 * 1024 else { throw ProjectSettingsError.tooLarge }
        try ProjectAtomicFile.write(bytes, to: fileURL, permissions: 0o644, expectedDigest: .some(expectedDigest))
        return try Self.decode(bytes)
    }

    private func ensureDirectory(create: Bool) throws {
        let directory = root.appendingPathComponent(".db3")
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ProjectSettingsError.unavailable }
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw ProjectSettingsError.unavailable }
        } else if errno == ENOENT {
            if create {
                guard mkdir(directory.path, 0o755) == 0 || errno == EEXIST else { throw errno == EACCES || errno == EROFS ? ProjectSettingsError.readOnly : .unavailable }
                guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ProjectSettingsError.unavailable }
            }
        } else { throw ProjectSettingsError.unavailable }
    }

    private static func decode(_ bytes: Data) throws -> ProjectSettingsDocument {
        do {
            let json = try JSONDecoder().decode(ProjectJSONValue.self, from: bytes)
            guard case .object(let root) = json, let version = root["version"]?.integer else { throw ProjectSettingsError.invalidFormat }
            guard version == 1 else { throw ProjectSettingsError.unsupportedVersion(version) }
            guard root["namespaces"] == nil || root["namespaces"]?.object != nil,
                  root["bindings"] == nil || root["bindings"]?.object != nil,
                  root["objectOverrides"] == nil || root["objectOverrides"]?.array != nil,
                  root["adapter"] == nil || root["adapter"]?.string != nil || root["adapter"]?.isNull == true else { throw ProjectSettingsError.invalidFormat }
            let namespace = root["namespaces"]?.object ?? [:]
            guard namespace["showBase"] == nil || namespace["showBase"]?.bool != nil,
                  namespace["order"] == nil || namespace["order"]?.array != nil,
                  namespace["displayNames"] == nil || namespace["displayNames"]?.object != nil else { throw ProjectSettingsError.invalidFormat }
            var bindings: [String: ProjectLogicalBinding] = [:]
            for (key, value) in root["bindings"]?.object ?? [:] {
                guard let source = value.object?["sourceGroup"]?.string else { throw ProjectSettingsError.invalidFormat }
                bindings[key] = .init(sourceGroup: source)
            }
            let overrides = try (root["objectOverrides"]?.array ?? []).map { value -> ProjectObjectOverride in
                guard let row = value.object, let binding = row["binding"]?.string, let schema = row["schema"]?.string,
                      let relation = row["relation"]?.string, let namespace = row["namespace"]?.string else { throw ProjectSettingsError.invalidFormat }
                return .init(binding: binding, schema: schema, relation: relation, namespace: namespace)
            }
            let order = try (namespace["order"]?.array ?? []).map { value in guard let string = value.string else { throw ProjectSettingsError.invalidFormat }; return string }
            var labels: [String: String] = [:]
            for (key, value) in namespace["displayNames"]?.object ?? [:] { guard let string = value.string else { throw ProjectSettingsError.invalidFormat }; labels[key] = string }
            let settings = ProjectSettings(adapter: root["adapter"]?.string,
                namespaces: .init(showBase: namespace["showBase"]?.bool ?? false, order: order, displayNames: labels), bindings: bindings, objectOverrides: overrides)
            try validate(settings)
            return ProjectSettingsDocument(settings: settings, digest: ProjectFingerprint.digest(bytes), original: root)
        } catch let error as ProjectSettingsError { throw error }
        catch { throw ProjectSettingsError.invalidFormat }
    }

    private static func encode(_ document: ProjectSettingsDocument) throws -> Data {
        let settings = document.settings
        var root = document.original
        root["version"] = .number(1)
        root["adapter"] = settings.adapter.map(ProjectJSONValue.string)
        var namespaces = root["namespaces"]?.object ?? [:]
        namespaces["showBase"] = .bool(settings.namespaces.showBase)
        namespaces["order"] = .array(settings.namespaces.order.map(ProjectJSONValue.string))
        namespaces["displayNames"] = .object(settings.namespaces.displayNames.mapValues(ProjectJSONValue.string))
        root["namespaces"] = .object(namespaces)
        let oldBindings = root["bindings"]?.object ?? [:]
        root["bindings"] = .object(settings.bindings.mapValues { value in .object(["sourceGroup": .string(value.sourceGroup)]) })
        if case .object(var bindings) = root["bindings"] {
            for (key, binding) in settings.bindings {
                var original = oldBindings[key]?.object ?? [:]
                original["sourceGroup"] = .string(binding.sourceGroup); bindings[key] = .object(original)
            }
            root["bindings"] = .object(bindings)
        }
        let oldRows = root["objectOverrides"]?.array ?? []
        root["objectOverrides"] = .array(settings.objectOverrides.map { override in
            var row = oldRows.first(where: { value in value.object?["binding"]?.string == override.binding && value.object?["schema"]?.string == override.schema && value.object?["relation"]?.string == override.relation })?.object ?? [:]
            row["binding"] = .string(override.binding); row["schema"] = .string(override.schema)
            row["relation"] = .string(override.relation); row["namespace"] = .string(override.namespace)
            return .object(row)
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(ProjectJSONValue.object(root)); bytes.append(10); return bytes
    }

    private static func validate(_ settings: ProjectSettings) throws {
        guard settings.version == 1 else { throw ProjectSettingsError.unsupportedVersion(settings.version) }
        guard settings.bindings.count <= 256, settings.objectOverrides.count <= 10_000,
              settings.namespaces.order.count <= 512, settings.namespaces.displayNames.count <= 512 else { throw ProjectSettingsError.tooLarge }
        func text(_ string: String, maximum: Int = 1024) -> Bool { !string.isEmpty && string.utf8.count <= maximum && !string.utf8.contains(0) }
        for (key, binding) in settings.bindings {
            guard logicalKey(key), ProjectDotEnvParser.validKey(binding.sourceGroup) else { throw ProjectSettingsError.invalidFormat }
        }
        guard settings.objectOverrides.allSatisfy({ logicalKey($0.binding) && text($0.schema) && text($0.relation) && text($0.namespace, maximum: 128) }),
              Set(settings.objectOverrides.map(\.id)).count == settings.objectOverrides.count,
              settings.namespaces.order.allSatisfy({ text($0, maximum: 128) }),
              settings.namespaces.displayNames.allSatisfy({ text($0.key, maximum: 128) && text($0.value, maximum: 128) }) else { throw ProjectSettingsError.invalidFormat }
        if let adapter = settings.adapter, !logicalKey(adapter) { throw ProjectSettingsError.invalidFormat }
    }
    static func logicalKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 100 && key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
}

/// Unknown fields retain their typed JSON values, including large exact decimal
/// integers rather than round-tripping through binary Double.
fileprivate enum ProjectJSONValue: Codable, Sendable {
    case object([String: Self]), array([Self]), string(String), number(Decimal), bool(Bool), null
    var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var isNull: Bool { if case .null = self { true } else { false } }
    var integer: Int? { if case .number(let value) = self, value == Decimal(NSDecimalNumber(decimal: value).intValue) { NSDecimalNumber(decimal: value).intValue } else { nil } }
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Decimal.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum ProjectAtomicFile {
    /// outer nil means private-state unconditional replace; .some(nil) means
    /// a missing project file was loaded and must still be missing.
    static func write(_ bytes: Data, to url: URL, permissions: mode_t, expectedDigest: String?? = nil) throws {
        let parent = url.deletingLastPathComponent()
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw errno == EACCES || errno == EROFS ? ProjectSettingsError.readOnly : .unavailable }
        defer { close(directory) }
        var parentInfo = stat()
        guard fstat(directory, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR else { throw ProjectSettingsError.unavailable }
        guard parentInfo.st_mode & 0o222 != 0 else { throw ProjectSettingsError.readOnly }
        func checkRevision() throws {
            var currentParent = stat()
            guard lstat(parent.path, &currentParent) == 0, currentParent.st_mode & S_IFMT == S_IFDIR,
                  currentParent.st_dev == parentInfo.st_dev, currentParent.st_ino == parentInfo.st_ino else { throw ProjectSettingsError.conflict }
            guard let expected = expectedDigest else { return }
            let current: Data?
            do { current = try ProjectFileIO.readIfPresent(url.lastPathComponent, relativeTo: directory, maximumBytes: 2 * 1024 * 1024) }
            catch { throw ProjectSettingsError.unavailable }
            guard current.map(ProjectFingerprint.digest) == expected else { throw ProjectSettingsError.conflict }
        }
        try checkRevision()
        let temporary = ".db3-write-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        guard descriptor >= 0 else { throw errno == EACCES || errno == EROFS ? ProjectSettingsError.readOnly : .unavailable }
        var closed = false
        defer { if !closed { close(descriptor) }; unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProjectSettingsError.unavailable }
                written += count
            }
        }
        guard fchmod(descriptor, permissions) == 0, fsync(descriptor) == 0 else { throw ProjectSettingsError.unavailable }
        close(descriptor); closed = true
        try checkRevision()
        // Never replace a symlink, including one introduced after the last read.
        var info = stat()
        if fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw ProjectSettingsError.unavailable }
            guard info.st_mode & 0o222 != 0 else { throw ProjectSettingsError.readOnly }
        }
        guard renameat(directory, temporary, directory, url.lastPathComponent) == 0 else { throw errno == EACCES || errno == EROFS ? ProjectSettingsError.readOnly : .unavailable }
        _ = fsync(directory)
    }
}
