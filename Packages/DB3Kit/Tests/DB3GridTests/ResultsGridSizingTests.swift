import AppKit
import XCTest
import DB3Core
@testable import DB3Grid

/// These exercise native views offscreen; they do not open or control a window.
@MainActor
final class ResultsGridSizingTests: XCTestCase {
    func testContentWidthsStayCompactAndRecoverAfterNarrowResize() async throws {
        let grid = sampleGrid()
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        // Hold scrollbar gutters constant for the width roundtrip assertion.
        // Other cases exercise the production autohiding configuration.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 900)
        try await waitUntil { table.tableColumns[2].width > 300 && self.totalWidth(table) < 800 }
        assertLeavesSpace(scroll, table: table)
        let original = table.tableColumns.map(\.width)

        resize(scroll, width: 1250)
        try await Task.sleep(for: .milliseconds(80))
        assertLeavesSpace(scroll, table: table)
        XCTAssertEqual(table.tableColumns.map(\.width), original)

        resize(scroll, width: 360)
        try await waitUntil { table.tableColumns[2].width < original[2] - 50 && abs(self.totalWidth(table) - scroll.contentView.bounds.width) < 1 }
        assertFits(scroll, table: table)
        XCTAssertGreaterThan(table.tableColumns[2].width, table.tableColumns[1].width)
        XCTAssertTrue(table.tableColumns.dropFirst().allSatisfy { $0.width >= 64 })

        resize(scroll, width: 900)
        try await waitUntil { abs(table.tableColumns[2].width - original[2]) < 1 }
        assertLeavesSpace(scroll, table: table)
        for (column, expected) in zip(table.tableColumns, original) {
            XCTAssertEqual(column.width, expected, accuracy: 1)
        }
    }

    func testManualWidthSurvivesResizeAndResetsForNewResult() async throws {
        let grid = sampleGrid()
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 900)
        try await waitUntil { table.tableColumns[2].width > 300 }

        table.tableColumns[1].width = 180
        resize(scroll, width: 1100)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(table.tableColumns[1].width, 180, accuracy: 0.1)
        assertLeavesSpace(scroll, table: table)
        resize(scroll, width: 500)
        try await waitUntil { abs(self.totalWidth(table) - scroll.contentView.bounds.width) < 1 }
        XCTAssertEqual(table.tableColumns[1].width, 180, accuracy: 0.1)

        coordinator.update(parent: sampleGrid(revision: 1))
        try await waitUntil { table.tableColumns[1].width < 120 && table.tableColumns[2].width > 200 }
        assertFits(scroll, table: table)
    }

    func testNarrowViewportKeepsReadableColumnsAndScrollDoesNotChangeWidths() async throws {
        let grid = sampleGrid()
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 900)
        try await waitUntil { table.tableColumns[2].width > 300 }
        resize(scroll, width: 190)
        try await waitUntil { table.tableColumns.dropFirst().allSatisfy { $0.width < 190 } }
        XCTAssertTrue(table.tableColumns.dropFirst().allSatisfy { $0.width >= 64 })
        XCTAssertGreaterThan(totalWidth(table), scroll.contentView.bounds.width)
        let beforeScroll = table.tableColumns.map(\.width)
        scroll.contentView.scroll(to: NSPoint(x: 30, y: 1800))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.tableColumns.map(\.width), beforeScroll)
    }

    func testRapidManualDragBackToOriginalWidthDoesNotSnapToIntermediateWidth() async throws {
        let grid = sampleGrid()
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 900)
        try await waitUntil { table.tableColumns[2].width > 300 }
        let original = table.tableColumns[1].width
        table.tableColumns[1].width = 220
        table.tableColumns[1].width = original
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(table.tableColumns[1].width, original, accuracy: 0.1)
        assertLeavesSpace(scroll, table: table)
    }

    func testScrollbarGutterChangesReflowAgainstActualClipWidth() async throws {
        let grid = sampleGrid()
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        resize(scroll, width: 500)
        try await waitUntil { table.tableColumns[2].width > 200 && abs(self.totalWidth(table) - scroll.contentView.bounds.width) < 1 }
        let withGutter = table.tableColumns[2].width
        scroll.hasVerticalScroller = false
        scroll.tile()
        try await waitUntil { table.tableColumns[2].width > withGutter && abs(self.totalWidth(table) - scroll.contentView.bounds.width) < 1 }
        assertFits(scroll, table: table)
        scroll.hasVerticalScroller = true
        scroll.tile()
        try await waitUntil { abs(table.tableColumns[2].width - withGutter) < 1 }
        assertFits(scroll, table: table)
    }

    func testCountResultFitsContentAndStaysNearRowNumberOnWideWindows() async throws {
        let grid = ResultsGrid(columns: [DatabaseColumn(index: 0, name: "count", typeOID: 20)], rowCount: 1, revision: 0, loadRows: { range in range.map { _ in [.text("227118")] } })
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 2200)
        try await Task.sleep(for: .milliseconds(100))
        let countColumn = table.tableColumns[1]
        let original = countColumn.width
        let textWidth = ("227118" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
        let headerWidth = ("count" as NSString).size(withAttributes: [.font: try XCTUnwrap(countColumn.headerCell.font)]).width
        XCTAssertGreaterThanOrEqual(original, ceil(max(textWidth + 20, headerWidth + 24)))
        XCTAssertLessThan(original, 100)
        XCTAssertEqual(countColumn.headerCell.alignment, .right)
        XCTAssertLessThan(table.rect(ofColumn: 1).maxX, 160)
        assertLeavesSpace(scroll, table: table)
        resize(scroll, width: 500)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(countColumn.width, original, accuracy: 0.1)
        assertLeavesSpace(scroll, table: table)
    }

    func testEmptyResultsStillSizeHeadersAndStoppedGridDoesNotUpdate() async throws {
        let grid = ResultsGrid(columns: [DatabaseColumn(index: 0, name: "id"), DatabaseColumn(index: 1, name: "Long descriptive column header")], rowCount: 0, revision: 0, loadRows: { _ in [] })
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 700)
        try await waitUntil { table.tableColumns[2].width > 180 && table.tableColumns[2].width < 320 }
        assertLeavesSpace(scroll, table: table)
        let original = table.tableColumns.map(\.width)
        ResultsGrid.dismantleNSView(scroll, coordinator: coordinator)
        resize(scroll, width: 1000)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(table.tableColumns.map(\.width), original)
    }

    private func sampleGrid(revision: Int = 0) -> ResultsGrid {
        let columns = [DatabaseColumn(index: 0, name: "id", typeOID: 23), DatabaseColumn(index: 1, name: "email"), DatabaseColumn(index: 2, name: "name")]
        return ResultsGrid(columns: columns, rowCount: 200, revision: revision, loadRows: { range in
            range.map { [.text(String($0 + 1)), .text("long.email.address.\($0)@example.customer-domain.com"), .text("Alexandra Smith")] }
        })
    }

    private func resize(_ scroll: NSScrollView, width: CGFloat) {
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        scroll.tile()
    }

    private func totalWidth(_ table: NSTableView) -> CGFloat {
        // Inspect native geometry instead of repeating the allocator's arithmetic.
        table.rect(ofColumn: table.numberOfColumns - 1).maxX
    }

    private func assertFits(_ scroll: NSScrollView, table: NSTableView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(totalWidth(table), scroll.contentView.bounds.width, accuracy: 1, file: file, line: line)
        XCTAssertLessThanOrEqual(table.frame.width, scroll.contentView.bounds.width + 1, file: file, line: line)
    }

    private func assertLeavesSpace(_ scroll: NSScrollView, table: NSTableView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(totalWidth(table), scroll.contentView.bounds.width - 20, file: file, line: line)
        XCTAssertLessThanOrEqual(table.frame.width, scroll.contentView.bounds.width + 1, file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        var settled = 0
        for _ in 0..<150 {
            settled = condition() ? settled + 1 : 0
            if settled >= 3 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Grid layout did not settle", file: file, line: line)
    }
}
