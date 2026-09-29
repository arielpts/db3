import Foundation
import CoreServices
import Darwin

private final class ProjectWatcherContext: @unchecked Sendable {
    weak var owner: ProjectFolderWatcher?
    let generation: UUID
    init(owner: ProjectFolderWatcher, generation: UUID) { self.owner = owner; self.generation = generation }
}

public struct ProjectFolderChange: Equatable, Sendable {
    public let paths: Set<String>
    public let requiresFullRescan: Bool
    public init(paths: Set<String> = [], requiresFullRescan: Bool = false) {
        self.paths = paths; self.requiresFullRescan = requiresFullRescan
    }
}

/// Events are invalidation hints, never an authoritative file inventory. All
/// paths are relative to the selected root. Overflow and dropped FSEvents history
/// collapse into a single full-rescan request rather than retaining more paths.
struct ProjectChangeAccumulator: Sendable {
    static let maximumPaths = 2048
    static let maximumPathBytes = 512 * 1024
    private(set) var paths: Set<String> = []
    private(set) var requiresFullRescan = false
    private var pathBytes = 0
    var isEmpty: Bool { paths.isEmpty && !requiresFullRescan }

    mutating func append(_ path: String?, fullRescan: Bool = false) {
        if fullRescan { requiresFullRescan = true; paths.removeAll(keepingCapacity: true); pathBytes = 0 }
        guard !requiresFullRescan, let path else { return }
        guard !paths.contains(path) else { return }
        if paths.count >= Self.maximumPaths || pathBytes + path.utf8.count > Self.maximumPathBytes {
            append(nil, fullRescan: true); return
        }
        paths.insert(path); pathBytes += path.utf8.count
    }
    mutating func take() -> ProjectFolderChange {
        let result = ProjectFolderChange(paths: paths, requiresFullRescan: requiresFullRescan)
        self = .init(); return result
    }
}

/// One watcher per opened project, owned by its workspace rather than a view.
/// The callback runs on a private utility queue. start/stop are synchronous and
/// thread-safe; after stop returns no callback can still be running or begin.
public final class ProjectFolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.db3.project-files", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let root: URL
    private let rootPath: String
    private let onChange: @Sendable (ProjectFolderChange) -> Void
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var firstEvent: DispatchTime?
    private var accumulator = ProjectChangeAccumulator()
    private var running = false
    private var generation = UUID()
    private let debounceNanoseconds: UInt64 = 300_000_000
    private let maximumWaitNanoseconds: UInt64 = 1_500_000_000

    public init(root: URL, onChange: @escaping @Sendable (ProjectFolderChange) -> Void) {
        // FSEvents returns real filesystem paths (for example /private/var).
        // Foundation may abbreviate those aliases to /var, breaking prefix
        // matching even though the watched files are inside the selected root.
        if let resolved = realpath(root.path, nil) {
            self.root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        } else { self.root = root.standardizedFileURL }
        rootPath = self.root.path
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: 1)
    }

    public func start() throws {
        try synchronized {
            guard !running else { return }
            generation = UUID()
            let reference = ProjectWatcherContext(owner: self, generation: generation)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(reference).toOpaque(), retain: { raw in
                guard let raw else { return nil }
                _ = Unmanaged<ProjectWatcherContext>.fromOpaque(raw).retain(); return raw
            }, release: { raw in
                if let raw { Unmanaged<ProjectWatcherContext>.fromOpaque(raw).release() }
            }, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
                guard let info else { return }
                let reference = Unmanaged<ProjectWatcherContext>.fromOpaque(info).takeUnretainedValue()
                guard let owner = reference.owner else { return }
                let paths = unsafeBitCast(rawPaths, to: NSArray.self)
                owner.receive(count: count, paths: paths, flags: flags, generation: reference.generation)
            }, &context, [rootPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
                throw ProjectConfigurationError.unavailable
            }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
                throw ProjectConfigurationError.unavailable
            }
            running = true
        }
    }

    public func stop() {
        synchronized {
            running = false
            timer?.cancel(); timer = nil; firstEvent = nil; accumulator = .init()
            if let stream {
                FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }
    deinit { stop() }

    private func synchronized<T>(_ action: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try action() }
        return try queue.sync(execute: action)
    }

    private func receive(count: Int, paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>, generation: UUID) {
        guard running, generation == self.generation else { return }
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount)
        // The system can provide a large batch. Scan at most the retained-path
        // bound and conservatively reconcile everything if the batch is larger.
        if count > ProjectChangeAccumulator.maximumPaths { accumulator.append(nil, fullRescan: true) }
        else {
            for index in 0..<min(count, paths.count) {
                if flags[index] & dropped != 0 { accumulator.append(nil, fullRescan: true); break }
                guard let path = paths[index] as? String, let relative = Self.relativePath(path, root: rootPath) else { continue }
                if relative.isEmpty { accumulator.append(nil, fullRescan: true) }
                else if !Self.excluded(relative) { accumulator.append(relative) }
            }
        }
        schedule()
    }

    private func schedule() {
        guard !accumulator.isEmpty else { return }
        let now = DispatchTime.now()
        if firstEvent == nil { firstEvent = now }
        let deadline = min(now.uptimeNanoseconds + debounceNanoseconds, firstEvent!.uptimeNanoseconds + maximumWaitNanoseconds)
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.flush() }
            self.timer = timer; timer.resume()
        }
        timer?.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .milliseconds(20))
    }
    private func flush() {
        guard running else { return }
        timer?.cancel(); timer = nil; firstEvent = nil
        guard !accumulator.isEmpty else { return }
        onChange(accumulator.take())
    }
    static func relativePath(_ absolute: String, root: String) -> String? {
        if absolute == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard absolute.hasPrefix(prefix) else { return nil }
        let relative = String(absolute.dropFirst(prefix.count))
        guard !relative.split(separator: "/").contains("..") else { return nil }
        return relative
    }
    static func excluded(_ path: String) -> Bool {
        let ignored: Set<String> = [".git", ".venv", "venv", "__pycache__", "node_modules", ".build", "DerivedData", ".mypy_cache", ".pytest_cache", "uploads", "filestore"]
        let parts = path.split(separator: "/")
        if parts.contains(where: { ignored.contains(String($0)) }) { return true }
        // The portable settings file itself is watched; temporary atomic-write
        // files never contain relevant configuration independently.
        return parts.count == 2 && parts[0] == ".db3" && parts[1].hasPrefix(".db3-write-")
    }
}
