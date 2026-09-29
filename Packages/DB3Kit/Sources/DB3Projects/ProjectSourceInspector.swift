import Foundation
import CryptoKit
import Darwin

/// Bounded source inspection. The detached worker owns every parser and tree; only immutable facts cross actors.
public actor ProjectSourceInspector: ProjectInspectionAdapter {
    public nonisolated let adapterID = "odoo"
    public nonisolated let adapterVersion = "1"
    public nonisolated let capabilities: Set<ProjectAdapterCapability> = [.models, .fields, .choices, .relationships, .computedFields, .namespaces, .sourceDependencies]
    private let limits: ProjectInspectionLimits
    private var cache: [String: SourceCacheEntry] = [:]
    private var rootPath: String?
    private var worker: Task<SourceScanResult, Error>?
    private var requestID = UUID()
    public init(limits: ProjectInspectionLimits = .init()) { self.limits = limits }
    public func cancel() async {
        let id = UUID(); requestID = id; worker?.cancel()
        if let worker { _ = try? await worker.value }
        if requestID == id { self.worker = nil }
    }
    public func inspect(root: URL, generation: UUID = UUID(), changedPaths: Set<String> = [], force: Bool = false) async throws -> ProjectInspectionSnapshot {
        let id = UUID(); requestID = id
        worker?.cancel()
        if let worker { _ = try? await worker.value }
        guard requestID == id else { throw CancellationError() }
        try Task.checkCancellation()
        let canonical = canonicalProjectURL(root)
        if rootPath != canonical.path { cache = [:]; rootPath = canonical.path }
        let previous = cache, limits = limits
        let task = Task.detached(priority: .utility) {
            try SourceScanner(root: canonical, generation: generation, changedPaths: changedPaths, force: force, limits: limits, previous: previous).scan()
        }
        worker = task
        return try await withTaskCancellationHandler {
            let result = try await task.value
            guard requestID == id else { throw CancellationError() }
            cache = result.cache; worker = nil
            return result.snapshot
        } onCancel: { task.cancel() }
    }
}
private struct SourceCacheEntry: Sendable {
    let size: Int, modified: Date, digest: String, bytes: Int
    let facts: PythonFileFacts
}
private struct SourceScanResult: Sendable { let snapshot: ProjectInspectionSnapshot, cache: [String: SourceCacheEntry] }
private struct SourceDigestInput: Encodable {
    let adapterID: String, roots: [ProjectSourceRoot], frameworkVersion: String?, files: [String]
    let diagnostics: [ProjectInspectionDiagnostic], completeness: ProjectInspectionCompleteness
}
private struct SourceCandidate { let url: URL, relative: String, sourceRoot: ProjectSourceRoot, size: Int, modified: Date }
private struct SourceScanner {
    let root: URL, generation: UUID, changedPaths: Set<String>, force: Bool, limits: ProjectInspectionLimits
    let previous: [String: SourceCacheEntry]
    private let excluded: Set<String> = [".git", ".venv", "venv", "env", "node_modules", "__pycache__", ".mypy_cache", ".pytest_cache", "build", "dist", "filestore", "uploads", "coverage", "tests", "test", "static", "i18n", "migrations"]
    func scan() throws -> SourceScanResult {
        let start = Date(), manager = FileManager.default
        var diagnostics: [ProjectInspectionDiagnostic] = [], partial = false
        func diagnose(_ code: String, _ message: String, path: String? = nil) {
            partial = true
            if diagnostics.count < limits.maximumDiagnostics { diagnostics.append(.init(code: code, message: message, relativePath: path)) }
        }
        let discovery = discoverRoots(diagnostics: &diagnostics)
        let roots = discovery.roots
        var candidates: [SourceCandidate] = [], seen = Set<String>(), count = 0
        for sourceRoot in roots {
            try Task.checkCancellation()
            let location = root.appendingPathComponent(sourceRoot.relativePath).standardizedFileURL
            guard contained(canonicalProjectURL(location), by: root), !isSymlink(location) else {
                diagnose("unsafe-source-root", "A source root points outside the project or is a symbolic link.", path: sourceRoot.relativePath); continue
            }
            guard manager.fileExists(atPath: location.path) else {
                diagnose("missing-source-root", "An active source root is not available.", path: sourceRoot.relativePath); continue
            }
            guard let enumerator = manager.enumerator(at: location, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [], errorHandler: { _, _ in true }) else { continue }
            for case let file as URL in enumerator {
                try Task.checkCancellation(); count += 1
                if count > limits.maximumFiles * 8 { diagnose("directory-budget", "Directory enumeration reached its bounded entry limit."); break }
                let relative = String(file.path.dropFirst(root.path.count + 1)), name = file.lastPathComponent
                let info = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                if info?.isSymbolicLink == true { enumerator.skipDescendants(); diagnose("skipped-symlink", "Symbolic links are excluded from source inspection.", path: relative); continue }
                if info?.isDirectory == true {
                    if excluded.contains(name) || name.hasPrefix(".") || enumerator.level > 32 { enumerator.skipDescendants() }
                    continue
                }
                guard info?.isRegularFile == true, file.pathExtension == "py", seen.insert(relative).inserted else { continue }
                if candidates.count >= limits.maximumFiles { diagnose("file-budget", "Source inspection reached its file count limit."); break }
                guard let size = info?.fileSize, size <= limits.maximumFileBytes else { diagnose("large-source-file", "A source file exceeds the per-file inspection limit.", path: relative); continue }
                candidates.append(.init(url: file, relative: relative, sourceRoot: sourceRoot, size: size, modified: info?.contentModificationDate ?? .distantPast))
            }
        }
        let manifestFolders = Set(candidates.filter { $0.url.lastPathComponent == "__manifest__.py" }.map { $0.url.deletingLastPathComponent().path })
        var cache: [String: SourceCacheEntry] = [:], parsed = 0, metadataBytes = 0
        for candidate in candidates.sorted(by: { $0.sourceRoot.priority == $1.sourceRoot.priority ? $0.relative < $1.relative : $0.sourceRoot.priority < $1.sourceRoot.priority }) {
            try Task.checkCancellation()
            guard let identity = moduleIdentity(candidate, manifests: manifestFolders) else { continue }
            let old = previous[candidate.relative]
            let explicitlyChanged = changedPaths.contains(candidate.relative) || changedPaths.contains(candidate.url.path)
            if !force, !explicitlyChanged, let old, old.size == candidate.size, old.modified == candidate.modified,
               old.facts.modulePath == identity.path, old.facts.isBase == candidate.sourceRoot.isBase {
                guard metadataBytes + old.bytes <= limits.maximumMetadataBytes / 2 else { diagnose("metadata-budget", "Source facts reached the metadata memory budget."); break }
                cache[candidate.relative] = old; metadataBytes += old.bytes
                if old.facts.stale { diagnose("source-parse-failed", "Source inspection failed; the last successful facts, if available, remain visibly stale.", path: candidate.relative) }
                continue
            }
            do {
                let data = try readSource(candidate.url, maximum: limits.maximumFileBytes)
                let digest = hexDigest(data)
                if !force, !explicitlyChanged, let old, old.digest == digest, !old.facts.stale,
                   old.facts.modulePath == identity.path, old.facts.isBase == candidate.sourceRoot.isBase {
                    cache[candidate.relative] = .init(size: candidate.size, modified: candidate.modified, digest: digest, bytes: old.bytes, facts: old.facts)
                    metadataBytes += old.bytes; continue
                }
                parsed += 1
                let facts = try PythonSyntax(bytes: Array(data)).parse(relativePath: candidate.relative, modulePath: identity.path, moduleName: identity.module, isBase: candidate.sourceRoot.isBase, digest: digest)
                let bytes = facts.retainedBytes
                guard metadataBytes + bytes <= limits.maximumMetadataBytes / 2 else { diagnose("metadata-budget", "Source facts reached the metadata memory budget."); break }
                cache[candidate.relative] = .init(size: candidate.size, modified: candidate.modified, digest: digest, bytes: bytes, facts: facts); metadataBytes += bytes
            } catch is CancellationError { throw CancellationError() }
            catch {
                diagnose("source-parse-failed", "Source inspection failed; the last successful facts, if available, remain visibly stale.", path: candidate.relative)
                if let old, metadataBytes + old.bytes <= limits.maximumMetadataBytes / 2 {
                    var stale = old.facts; stale.stale = true
                    cache[candidate.relative] = .init(size: candidate.size, modified: candidate.modified, digest: old.digest, bytes: old.bytes, facts: stale); metadataBytes += old.bytes
                } else {
                    let empty = PythonFileFacts(relativePath: candidate.relative, modulePath: identity.path, moduleName: identity.module,
                        digest: "unavailable", isBase: candidate.sourceRoot.isBase, imports: [], assignments: [], classes: [], manifest: nil, stale: true)
                    cache[candidate.relative] = .init(size: candidate.size, modified: candidate.modified, digest: "unavailable", bytes: 1024, facts: empty); metadataBytes += 1024
                }
            }
        }
        var extractionLimits = limits
        extractionLimits.maximumMetadataBytes = max(0, limits.maximumMetadataBytes - metadataBytes)
        let extracted = try OdooSourceExtractor(files: cache.values.map(\.facts).sorted { $0.isBase == $1.isBase ? $0.relativePath < $1.relativePath : !$0.isBase }, generation: generation, limits: extractionLimits).extract()
        diagnostics += extracted.diagnostics.prefix(max(0, limits.maximumDiagnostics - diagnostics.count))
        var models = extracted.models.sorted { $0.isBase == $1.isBase ? $0.name < $1.name : !$0.isBase }
        let encoder = JSONEncoder(); var modelBytes = 0, bounded: [ProjectModelMetadata] = []
        for model in models {
            let bytes = model.retainedBytes
            guard modelBytes + metadataBytes + bytes <= limits.maximumMetadataBytes else { diagnose("snapshot-budget", "Resolved metadata reached the snapshot memory budget."); break }
            bounded.append(model); modelBytes += bytes
        }
        models = bounded
        let recognized = discovery.evidence.contains("odoo_repositories.json") || !manifestFolders.isEmpty
        let adapterID = recognized ? "odoo" : "generic"
        if !recognized { diagnostics.append(.init(code: "generic-project", message: "No supported framework source metadata was detected. Project configuration and manual namespaces remain available.", severity: .information)) }
        if diagnostics.contains(where: { $0.severity != .information }) { partial = true }
        let completeness: ProjectInspectionCompleteness = partial ? .partial : .complete
        let signature = SourceDigestInput(adapterID: adapterID, roots: roots, frameworkVersion: discovery.version,
            files: cache.values.map { $0.facts.relativePath + ":" + $0.digest + ($0.facts.stale ? ":stale" : "") }.sorted(),
            diagnostics: diagnostics.sorted { $0.id < $1.id }, completeness: completeness)
        encoder.outputFormatting = [.sortedKeys]
        let rootDigest = hexDigest(try encoder.encode(signature))
        let detection = ProjectAdapterDetection(adapterID: adapterID, adapterVersion: "1", frameworkVersion: discovery.version,
            evidence: discovery.evidence, resolution: recognized ? .resolved : .inferred)
        let snapshot = ProjectInspectionSnapshot(generation: generation, rootDigest: rootDigest, adapterID: adapterID, detection: detection, roots: roots,
            models: models, diagnostics: diagnostics, completeness: completeness,
            sourceFileCount: candidates.count, parsedFileCount: parsed, metadataBytes: metadataBytes + modelBytes,
            elapsed: Date().timeIntervalSince(start), sourceDependencies: extracted.dependencies)
        return .init(snapshot: snapshot, cache: cache)
    }
    private func discoverRoots(diagnostics: inout [ProjectInspectionDiagnostic]) -> (roots: [ProjectSourceRoot], version: String?, evidence: [String]) {
        let config = root.appendingPathComponent("odoo_repositories.json")
        var roots: [ProjectSourceRoot] = [], version: String?, evidence: [String] = []
        if FileManager.default.fileExists(atPath: config.path) {
            do {
                let data = try readSource(config, maximum: limits.maximumFileBytes)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let repositories = object["repositories"] as? [[String: Any]] else { throw PythonSyntaxError.invalidSyntax }
                version = object["odoo_version"] as? String; evidence.append("odoo_repositories.json")
                for repository in repositories where repository["active"] as? Bool == true {
                    guard let path = repository["path"] as? String, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.isEmpty else {
                        diagnostics.append(.init(code: "invalid-source-root", message: "An active repository has an invalid relative source path.")); continue
                    }
                    let isBase = repository["core"] as? Bool == true || repository["org"] as? String == "OCA"
                    roots.append(.init(relativePath: path, isBase: isBase, priority: isBase ? 10 : 0))
                }
            } catch { diagnostics.append(.init(code: "repository-config-invalid", message: "The repository configuration cannot be read safely; source roots require review.", relativePath: "odoo_repositories.json")) }
        } else {
            for path in ["src", "addons", "odoo/addons"] {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &directory), directory.boolValue {
                    roots.append(.init(relativePath: path, isBase: path.hasPrefix("odoo/"), priority: 0)); evidence.append(path)
                }
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("__manifest__.py").path) { roots.append(.init(relativePath: ".", isBase: false, priority: 0)); evidence.append("__manifest__.py") }
        }
        if roots.count > limits.maximumSourceRoots { diagnostics.append(.init(code: "source-root-budget", message: "Source roots exceed the inspection budget.")) }
        return (Array(roots.sorted { $0.priority == $1.priority ? $0.relativePath < $1.relativePath : $0.priority < $1.priority }.prefix(limits.maximumSourceRoots)), version, evidence)
    }
    private func moduleIdentity(_ candidate: SourceCandidate, manifests: Set<String>) -> (path: String, module: String)? {
        var parent = candidate.url.deletingLastPathComponent()
        while contained(parent, by: root) {
            if manifests.contains(parent.path) {
                let module = parent.lastPathComponent
                var suffix = String(candidate.url.path.dropFirst(parent.path.count + 1)).replacingOccurrences(of: "/", with: ".")
                suffix = String(suffix.dropLast(3))
                if suffix == "__init__" { suffix = "" } else if suffix.hasSuffix(".__init__") { suffix = String(suffix.dropLast(9)) }
                return ("odoo.addons." + module + (suffix.isEmpty ? "" : "." + suffix), module)
            }
            if parent.path == root.path { break }; parent.deleteLastPathComponent()
        }
        // Framework modules provide aliases and constants but are not themselves addon namespaces.
        let components = candidate.relative.split(separator: "/").map(String.init)
        if let index = components.lastIndex(of: "odoo"), index + 1 < components.count {
            var path = components[index...].joined(separator: "."); path = String(path.dropLast(3))
            if path.hasSuffix(".__init__") { path = String(path.dropLast(9)) }
            return (path, "base")
        }
        return nil
    }
    private func isSymlink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    private func contained(_ url: URL, by parent: URL) -> Bool { url.path == parent.path || url.path.hasPrefix(parent.path + "/") }
    private func readSource(_ url: URL, maximum: Int) throws -> Data {
        guard contained(canonicalProjectURL(url), by: root) else { throw PythonSyntaxError.budget }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard contained(url, by: root), !components.isEmpty, !components.contains("..") else { throw CocoaError(.fileReadNoPermission) }
        var directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw CocoaError(.fileReadNoPermission) }
            Darwin.close(directory); directory = next
        }
        let fd = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }; defer { Darwin.close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= maximum else { throw PythonSyntaxError.budget }
        var data = Data(count: Int(before.st_size)), done = 0
        try data.withUnsafeMutableBytes { bytes in
            while done < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: done), bytes.count - done)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileReadUnknown) }; done += count
            }
        }
        var after = stat(); guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw CocoaError(.fileReadUnknown) }
        return data
    }
}
private func canonicalProjectURL(_ url: URL) -> URL {
    guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
    defer { free(path) }; return URL(fileURLWithPath: String(cString: path))
}
private func hexDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
