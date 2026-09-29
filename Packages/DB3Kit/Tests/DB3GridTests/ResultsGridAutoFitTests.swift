import AppKit
import XCTest
import DB3Core
@testable import DB3Grid

/// Exercise AppKit's divider auto-fit delegate without opening a window.
@MainActor
final class ResultsGridAutoFitTests: XCTestCase {
    func testDividerFitsOnlyItsLeftColumnAndPinsFitThroughResize() async throws {
        let grid = ResultsGrid(
            columns: [DatabaseColumn(index: 0, name: "id"), DatabaseColumn(index: 1, name: "email"), DatabaseColumn(index: 2, name: "name")],
            rowCount: 80,
            revision: 0,
            loadRows: { range in
                range.map { [.text(String($0)), .text("long.email.address@example.customer-domain.com"), .text("Alexandra Smith")] }
            }
        )
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 1100)
        try await waitUntil { table.tableColumns[2].width > 300 }
        let naturalEmailWidth = table.tableColumns[2].width
        let numberWidth = table.tableColumns[0].width

        table.tableColumns[1].width = 150
        table.tableColumns[2].width = 64
        table.tableColumns[3].width = 190
        let fitted = try fit(table, column: 2)
        XCTAssertEqual(fitted, naturalEmailWidth, accuracy: 0.1)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(table.tableColumns[0].width, numberWidth, accuracy: 0.1)
        XCTAssertEqual(table.tableColumns[1].width, 150, accuracy: 0.1)
        XCTAssertEqual(table.tableColumns[3].width, 190, accuracy: 0.1)

        // Both an overly narrow and an overly wide manual size converge to fit.
        table.tableColumns[2].width = 900
        XCTAssertEqual(try fit(table, column: 2), fitted, accuracy: 0.1)
        resize(scroll, width: 360)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(table.tableColumns[2].width, fitted, accuracy: 0.1)
        XCTAssertGreaterThan(table.rect(ofColumn: 3).maxX, scroll.contentView.bounds.width)
        resize(scroll, width: 1250)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(table.tableColumns[2].width, fitted, accuracy: 0.1)
    }

    func testLongContentFitIsCappedAndUsesAlreadyLoadedSample() async throws {
        let reads = RowReadRecorder()
        let grid = ResultsGrid(
            columns: [DatabaseColumn(index: 0, name: "details")],
            rowCount: 10_000,
            revision: 0,
            loadRows: { range in
                await reads.record(range)
                return range.map { _ in [.text(String(repeating: "long content ", count: 100))] }
            }
        )
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 1100)
        try await waitUntil { table.tableColumns[1].width == 480 }
        let before = await reads.requests
        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(before.allSatisfy { $0.count <= 64 })
        XCTAssertLessThan(before.reduce(0) { $0 + $1.count }, 10_000)

        table.tableColumns[1].width = 80
        XCTAssertEqual(try fit(table, column: 1), 480, accuracy: 0.1)
        try await Task.sleep(for: .milliseconds(80))
        let after = await reads.requests
        XCTAssertEqual(after, before, "Auto-fit must reuse cached measurements rather than load more rows.")
        XCTAssertEqual(table.tableColumns[1].width, 480, accuracy: 0.1)
    }

    func testEmptyResultFitsHeaderAndLeavesRowNumberUnchanged() async throws {
        let header = "Long descriptive column header"
        let grid = ResultsGrid(
            columns: [DatabaseColumn(index: 0, name: header)],
            rowCount: 0,
            revision: 0,
            loadRows: { _ in [] }
        )
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 900)
        try await waitUntil { table.tableColumns[1].width > 180 && table.tableColumns[1].width < 320 }
        let column = table.tableColumns[1]
        let expected = ceil((header as NSString).size(withAttributes: [.font: try XCTUnwrap(column.headerCell.font)]).width + 24)
        column.width = 64
        XCTAssertEqual(try fit(table, column: 1), expected, accuracy: 2)
        let numberWidth = table.tableColumns[0].width
        XCTAssertEqual(try fit(table, column: 0), numberWidth, accuracy: 0.1)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(table.tableColumns[0].width, numberWidth, accuracy: 0.1)
    }

    func testInvalidAndStoppedAutoFitRequestsDoNotChangeColumns() async throws {
        let grid = ResultsGrid(columns: [DatabaseColumn(index: 0, name: "id")], rowCount: 0, revision: 0, loadRows: { _ in [] })
        let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        resize(scroll, width: 900)
        try await Task.sleep(for: .milliseconds(80))
        let delegate = try XCTUnwrap(table.delegate)
        let original = table.tableColumns.map(\.width)
        XCTAssertEqual(try XCTUnwrap(delegate.tableView?(table, sizeToFitWidthOfColumn: -1)), 0)
        XCTAssertEqual(try XCTUnwrap(delegate.tableView?(table, sizeToFitWidthOfColumn: table.numberOfColumns)), 0)
        XCTAssertEqual(table.tableColumns.map(\.width), original)

        ResultsGrid.dismantleNSView(scroll, coordinator: coordinator)
        table.tableColumns[1].width = 200
        XCTAssertEqual(try XCTUnwrap(delegate.tableView?(table, sizeToFitWidthOfColumn: 1)), 200, accuracy: 0.1)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(table.tableColumns[1].width, 200, accuracy: 0.1)
    }

    private func fit(_ table: NSTableView, column index: Int) throws -> CGFloat {
        // AppKit asks the delegate for the width of the column left of the
        // double-clicked divider, then applies that width to its native column.
        let width = try XCTUnwrap(table.delegate?.tableView?(table, sizeToFitWidthOfColumn: index), "Grid must implement native divider auto-fit.")
        table.tableColumns[index].width = width
        return width
    }

    private func resize(_ scroll: NSScrollView, width: CGFloat) {
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        scroll.tile()
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

private actor RowReadRecorder {
    private(set) var requests: [Range<Int>] = []
    func record(_ range: Range<Int>) { requests.append(range) }
}
