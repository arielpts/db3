import Foundation
import XCTest
@testable import DB3Projects

final class ProjectFolderWatcherTests: XCTestCase, @unchecked Sendable {
    func testAccumulatorDeduplicatesAndCollapsesOverflowIntoFullRescan() {
        var accumulator = ProjectChangeAccumulator()
        accumulator.append("src/example.py"); accumulator.append("src/example.py")
        XCTAssertEqual(accumulator.take(), .init(paths: ["src/example.py"]))
        XCTAssertTrue(accumulator.isEmpty)
        for index in 0...ProjectChangeAccumulator.maximumPaths { accumulator.append("src/model_\(index).py") }
        XCTAssertTrue(accumulator.requiresFullRescan)
        XCTAssertTrue(accumulator.paths.isEmpty)
        accumulator.append("new.py")
        XCTAssertTrue(accumulator.paths.isEmpty)
        XCTAssertEqual(accumulator.take(), .init(requiresFullRescan: true))
        XCTAssertTrue(accumulator.isEmpty)
        accumulator.append(String(repeating: "x", count: ProjectChangeAccumulator.maximumPathBytes + 1))
        XCTAssertTrue(accumulator.requiresFullRescan)
    }

    func testDroppedHistoryAndRootChangesDiscardPartialPathAssumptions() {
        var accumulator = ProjectChangeAccumulator()
        accumulator.append(".env"); accumulator.append("src/example.py")
        accumulator.append(nil, fullRescan: true)
        XCTAssertEqual(accumulator.take(), .init(requiresFullRescan: true))
    }

    func testPathBoundaryAndExclusionsDoNotHideActiveOdooOrSettingsFiles() {
        XCTAssertEqual(ProjectFolderWatcher.relativePath("/project/src/example.py", root: "/project"), "src/example.py")
        XCTAssertEqual(ProjectFolderWatcher.relativePath("/project", root: "/project"), "")
        XCTAssertNil(ProjectFolderWatcher.relativePath("/project-other/.env", root: "/project"))
        XCTAssertNil(ProjectFolderWatcher.relativePath("/project/../outside", root: "/project"))
        for path in [".git/index", ".venv/model.py", "src/__pycache__/model.pyc", ".db3/.db3-write-example"] {
            XCTAssertTrue(ProjectFolderWatcher.excluded(path), path)
        }
        for path in [".env", ".db3/project.json", ".odoo/odoo/addons/base/models/example.py", ".odoo/oca/queue/example.py", "src/example.py"] {
            XCTAssertFalse(ProjectFolderWatcher.excluded(path), path)
        }
    }

    func testNativeEventsCoalesceAndStopPreventsFurtherCallbacks() async throws {
        let folder = try ProjectConfigTestFolder()
        let changes = ProjectWatchTestChanges()
        var watcher: ProjectFolderWatcher? = ProjectFolderWatcher(root: folder.url) { changes.append($0) }
        weak let weakWatcher = watcher
        try watcher?.start()
        try watcher?.start() // idempotent
        for index in 0..<12 { try folder.write("source_\(index).py", "value = \(index)") }
        let deadline = ContinuousClock.now + .seconds(5)
        while changes.snapshot().isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(changes.snapshot().isEmpty, "No FSEvents invalidation arrived for fixture files")
        XCTAssertTrue(changes.snapshot().contains { $0.requiresFullRescan || $0.paths.contains("source_0.py") })
        watcher?.stop()
        let count = changes.snapshot().count
        try folder.write("late.py", "value = 99")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(changes.snapshot().count, count)
        watcher = nil
        XCTAssertNil(weakWatcher, "Stopped stream retained its watcher")
    }
}

private final class ProjectWatchTestChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProjectFolderChange] = []
    func append(_ item: ProjectFolderChange) { lock.lock(); defer { lock.unlock() }; items.append(item) }
    func snapshot() -> [ProjectFolderChange] { lock.lock(); defer { lock.unlock() }; return items }
}
