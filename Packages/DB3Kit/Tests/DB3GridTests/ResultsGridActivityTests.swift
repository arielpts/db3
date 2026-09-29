import AppKit
import XCTest
import DB3Core
@testable import DB3Grid

/// Retained tab/grid lifetime tests. All native views stay offscreen.
@MainActor
final class ResultsGridActivityTests: XCTestCase {
    func testInactiveGridDoesNotReadRowsAndResumesWhenActivated() async throws {
        let reads = ActivityReadRecorder()
        let grid = sampleGrid(active: false, reads: reads)
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll)
        _ = coordinator.tableView(table, viewFor: table.tableColumns[1], row: 0)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(80))
        let inactiveReads = await reads.requests
        XCTAssertTrue(inactiveReads.isEmpty)

        coordinator.update(parent: sampleGrid(active: true, reads: reads))
        try await waitUntil { self.cellText(coordinator, table: table, row: 0) == "row 0" }
        let activeReads = await reads.requests
        XCTAssertFalse(activeReads.isEmpty)
        XCTAssertTrue(scroll.documentView === table)
    }

    func testRepeatedActivationKeepsNativeColumnsScrollAndSelectionWithoutInspectorCallbacks() async throws {
        let reads = ActivityReadRecorder()
        var inspectedRows: [Int] = []
        let onSelect: @MainActor (Int, DatabaseColumn, DatabaseValue) -> Void = { row, _, _ in inspectedRows.append(row) }
        let grid = sampleGrid(active: true, reads: reads, onSelect: onSelect)
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll)
        try await waitUntil { self.cellText(coordinator, table: table, row: 0) == "row 0" }
        let columns = table.tableColumns
        columns[1].width = 420
        columns[2].width = 480
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 1800))
        scroll.reflectScrolledClipView(scroll.contentView)
        table.selectRowIndexes(IndexSet(integer: 67), byExtendingSelection: false)
        try await waitUntil { inspectedRows == [67] }
        try await Task.sleep(for: .milliseconds(80))
        let origin = scroll.contentView.bounds.origin
        let countBefore = await reads.requests.count

        for _ in 0..<3 {
            coordinator.update(parent: sampleGrid(active: false, reads: reads, onSelect: onSelect))
            // Even AppKit layout/data-source notifications for a hidden host
            // must not start an offscreen read or reopen its value inspector.
            _ = coordinator.tableView(table, viewFor: columns[1], row: 499)
            coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            try await Task.sleep(for: .milliseconds(40))
            let hiddenCount = await reads.requests.count
            XCTAssertEqual(hiddenCount, countBefore)

            coordinator.update(parent: sampleGrid(active: true, reads: reads, onSelect: onSelect))
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertTrue(scroll.documentView === table)
            for (current, original) in zip(table.tableColumns, columns) { XCTAssertTrue(current === original) }
            XCTAssertEqual(columns[1].width, 420, accuracy: 0.1)
            XCTAssertEqual(columns[2].width, 480, accuracy: 0.1)
            XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x, accuracy: 0.1)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.1)
            XCTAssertEqual(table.selectedRow, 67)
            XCTAssertEqual(inspectedRows, [67])
        }
    }

    func testInactiveAppendsRefetchPartialTailOnlyWhenActivated() async throws {
        let reads = ActivityReadRecorder()
        let grid = sampleGrid(active: true, count: 10, reads: reads)
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll)
        try await waitUntil { self.cellText(coordinator, table: table, row: 9) == "row 9" }
        coordinator.update(parent: sampleGrid(active: false, count: 10, reads: reads))
        let before = await reads.requests
        coordinator.update(parent: sampleGrid(active: false, count: 25, reads: reads))
        coordinator.update(parent: sampleGrid(active: false, count: 40, reads: reads))
        try await Task.sleep(for: .milliseconds(60))
        let after = await reads.requests
        XCTAssertEqual(after, before)
        XCTAssertEqual(table.numberOfRows, 10)

        coordinator.update(parent: sampleGrid(active: true, count: 40, reads: reads))
        try await waitUntil { self.cellText(coordinator, table: table, row: 39) == "row 39" }
        XCTAssertEqual(table.numberOfRows, 40)
        let resumed = await reads.requests
        XCTAssertEqual(resumed.last, 0..<40)
    }

    func testCancelledOldLoadsCannotReplaceNewResultOrDeliverSelectionAfterActivation() async throws {
        let oldRows = SuspendedActivityRows()
        var selectedValues: [DatabaseValue] = []
        let oldGrid = ResultsGrid(
            columns: [DatabaseColumn(index: 0, name: "old"), DatabaseColumn(index: 1, name: "old extra")],
            rowCount: 20,
            revision: 0,
            loadRows: { await oldRows.load($0) },
            onSelect: { _, _, value in selectedValues.append(value) }
        )
        let coordinator = oldGrid.makeCoordinator()
        let scroll = oldGrid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll)
        try await waitUntil { await oldRows.requestCount >= 1 }
        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        try await waitUntil { await oldRows.requestCount >= 2 }

        let newColumns = [DatabaseColumn(index: 0, name: "new")]
        let fresh: @Sendable (Range<Int>) async throws -> [DatabaseRow] = { range in range.map { _ in [.text("new result")] } }
        coordinator.update(parent: ResultsGrid(columns: newColumns, rowCount: 20, revision: 1, isActive: false, loadRows: fresh))
        // Keep the old native presentation while hidden, then synchronize once.
        XCTAssertEqual(table.numberOfColumns, 3)
        coordinator.update(parent: ResultsGrid(columns: newColumns, rowCount: 20, revision: 1, loadRows: fresh))
        try await waitUntil { self.cellText(coordinator, table: table, row: 3) == "new result" }
        await oldRows.resume()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(selectedValues.isEmpty)
        XCTAssertEqual(table.numberOfColumns, 2)
        XCTAssertEqual(table.tableColumns[1].title, "new")
        XCTAssertEqual(cellText(coordinator, table: table, row: 3), "new result")
    }

    private func sampleGrid(
        active: Bool,
        count: Int = 500,
        reads: ActivityReadRecorder,
        onSelect: (@MainActor (Int, DatabaseColumn, DatabaseValue) -> Void)? = nil
    ) -> ResultsGrid {
        ResultsGrid(
            columns: [DatabaseColumn(index: 0, name: "id"), DatabaseColumn(index: 1, name: "name")],
            rowCount: count,
            revision: 0,
            isActive: active,
            loadRows: { range in
                await reads.record(range)
                return range.map { [.text("row \($0)"), .text("value \($0)")] }
            },
            onSelect: onSelect
        )
    }

    private func cellText(_ coordinator: ResultsGrid.Coordinator, table: NSTableView, row: Int) -> String? {
        (coordinator.tableView(table, viewFor: table.tableColumns[1], row: row) as? NSTableCellView)?.textField?.stringValue
    }

    private func resize(_ scroll: NSScrollView) {
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        scroll.tile()
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Grid activity did not settle", file: file, line: line)
    }
}

private actor ActivityReadRecorder {
    private(set) var requests: [Range<Int>] = []
    func record(_ range: Range<Int>) { requests.append(range) }
}

/// Deliberately ignores cancellation to exercise the presentation-generation fence.
private actor SuspendedActivityRows {
    private var waiting: [(Range<Int>, CheckedContinuation<[DatabaseRow], Never>)] = []
    private(set) var requestCount = 0

    func load(_ range: Range<Int>) async -> [DatabaseRow] {
        requestCount += 1
        return await withCheckedContinuation { waiting.append((range, $0)) }
    }

    func resume() {
        for (range, continuation) in waiting {
            continuation.resume(returning: range.map { _ in [.text("stale result"), .text("stale extra")] })
        }
        waiting.removeAll()
    }
}
