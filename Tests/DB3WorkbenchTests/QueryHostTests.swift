import AppKit
import XCTest
import DB3Core
@testable import DB3Workbench

/// Exercise the real SwiftUI/AppKit bridge without creating any windows.
@MainActor
final class QueryHostTests: XCTestCase {
    func testTabRoundTripRetainsNativeEditorsUndoAndResultPresentation() async throws {
        let model = makeModel()
        let first = model.active
        first.sql = (0..<300).map { "SELECT \($0); -- first document" }.joined(separator: "\n")
        try await seedResults(first)
        model.addWorksheet()
        let second = model.active
        second.sql = "SELECT 'second document';"

        let hosts = QueryViewHosts()
        let container = QueryTabContentHost.Container()
        container.view.frame = NSRect(x: 0, y: 0, width: 940, height: 900)
        defer { container.clear(); hosts.prune(keeping: []) }
        let firstPage = hosts.page(for: first, model: model, kind: .worksheet)
        model.selectTab(first.id)
        container.show(firstPage, id: first.id, restoreFocus: false)
        try await settle(container.view) { self.editor(in: container.view) != nil && self.table(in: container.view) != nil }
        let firstEditor = try XCTUnwrap(editor(in: container.view))
        let firstTable = try XCTUnwrap(table(in: container.view))
        let firstSplit = try XCTUnwrap(descendants(of: NSSplitView.self, in: container.view).first)
        let firstUndo = try XCTUnwrap(firstEditor.undoManager)
        let editorScroll = try XCTUnwrap(firstEditor.enclosingScrollView)
        let resultScroll = try XCTUnwrap(firstTable.enclosingScrollView)
        XCTAssertNil(container.view.window)
        XCTAssertEqual(firstEditor.string, first.sql)

        firstUndo.beginUndoGrouping()
        firstEditor.insertText("-- retained edit\n", replacementRange: NSRange(location: 0, length: 0))
        firstUndo.endUndoGrouping()
        firstEditor.setSelectedRange(NSRange(location: 24, length: 8))
        firstEditor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: firstEditor))
        try await settle(container.view) { first.sql.hasPrefix("-- retained edit") }
        XCTAssertTrue(firstUndo.canUndo)
        firstTable.tableColumns[1].width = 600
        firstTable.tableColumns[2].width = 560
        firstTable.selectRowIndexes(IndexSet(integer: 70), byExtendingSelection: false)
        firstSplit.setPosition(315, ofDividerAt: 0)
        editorScroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
        resultScroll.contentView.scroll(to: NSPoint(x: 120, y: 1700))
        resultScroll.reflectScrolledClipView(resultScroll.contentView)
        try await settle(container.view) { first.selectedValue != nil }
        XCTAssertFalse(model.showingInspector, "Selecting a result cell must not open the inspector.")
        let editorOrigin = editorScroll.contentView.bounds.origin
        let resultOrigin = resultScroll.contentView.bounds.origin
        XCTAssertGreaterThan(editorOrigin.y, 0)
        XCTAssertGreaterThan(resultOrigin.x, 0)
        XCTAssertGreaterThan(resultOrigin.y, 0)
        let selection = firstEditor.selectedRange()
        let dividerPosition = firstSplit.subviews[0].frame.height
        let firstColumns = firstTable.tableColumns

        let secondPage = hosts.page(for: second, model: model, kind: .worksheet)
        model.selectTab(second.id)
        container.show(secondPage, id: second.id, restoreFocus: false)
        try await settle(container.view) { self.editor(in: container.view)?.string == second.sql }
        let secondEditor = try XCTUnwrap(editor(in: container.view))
        XCTAssertFalse(secondEditor === firstEditor)
        XCTAssertFalse(secondEditor.undoManager === firstUndo)
        XCTAssertNil(firstPage.controller.view.superview)
        XCTAssertFalse(firstEditor.isDescendant(of: container.view))
        XCTAssertEqual(cellText(firstTable, row: 499), "…")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cellText(firstTable, row: 499), "…", "An inactive retained host must pause its grid reads after detaching.")
        secondEditor.undoManager?.beginUndoGrouping()
        secondEditor.insertText("-- separate\n", replacementRange: NSRange(location: 0, length: 0))
        secondEditor.undoManager?.endUndoGrouping()
        secondEditor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: secondEditor))
        let secondSQL = secondEditor.string

        for _ in 0..<3 {
            model.selectTab(first.id)
            container.show(hosts.page(for: first, model: model, kind: .worksheet), id: first.id, restoreFocus: false)
            try await settle(container.view) { self.editor(in: container.view) === firstEditor }
            XCTAssertTrue(table(in: container.view) === firstTable)
            XCTAssertTrue(firstEditor.undoManager === firstUndo)
            XCTAssertTrue(firstUndo.canUndo)
            XCTAssertEqual(firstEditor.selectedRange(), selection)
            XCTAssertEqual(editorScroll.contentView.bounds.origin, editorOrigin)
            XCTAssertEqual(resultScroll.contentView.bounds.origin, resultOrigin)
            XCTAssertEqual(firstTable.selectedRow, 70)
            XCTAssertEqual(firstTable.tableColumns[1].width, 600, accuracy: 0.1)
            XCTAssertEqual(firstTable.tableColumns[2].width, 560, accuracy: 0.1)
            XCTAssertEqual(firstSplit.subviews[0].frame.height, dividerPosition, accuracy: 1)
            for (actual, original) in zip(firstTable.tableColumns, firstColumns) { XCTAssertTrue(actual === original) }

            model.selectTab(second.id)
            container.show(secondPage, id: second.id, restoreFocus: false)
            try await settle(container.view) { self.editor(in: container.view) === secondEditor }
        }

        model.selectTab(first.id)
        container.show(firstPage, id: first.id, restoreFocus: false)
        firstUndo.undo()
        try await settle(container.view) { !first.sql.hasPrefix("-- retained edit") }
        XCTAssertEqual(secondEditor.string, secondSQL)
        XCTAssertEqual(second.sql, secondSQL)
        await first.close()
        await second.close()
    }

    func testResultsMessagesRoundTripKeepsTheSameNativeTable() async throws {
        let model = makeModel()
        let sheet = model.active
        try await seedResults(sheet)
        let hosts = QueryViewHosts()
        let container = QueryTabContentHost.Container()
        container.view.frame = NSRect(x: 0, y: 0, width: 940, height: 900)
        defer { container.clear(); hosts.prune(keeping: []) }
        let page = hosts.page(for: sheet, model: model, kind: .worksheet)
        container.show(page, id: sheet.id, restoreFocus: false)
        try await settle(container.view) { self.table(in: container.view) != nil }
        let grid = try XCTUnwrap(table(in: container.view))
        let editor = try XCTUnwrap(editor(in: container.view))
        let outputPicker = try XCTUnwrap(descendants(of: NSSegmentedControl.self, in: container.view).first)
        let scroll = try XCTUnwrap(grid.enclosingScrollView)
        grid.tableColumns[1].width = 600
        grid.tableColumns[2].width = 560
        grid.selectRowIndexes(IndexSet(integer: 80), byExtendingSelection: false)
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 1900))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(container.view) { sheet.selectedValue != nil }
        let origin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(origin.x, 0)
        XCTAssertGreaterThan(origin.y, 0)

        for _ in 0..<3 {
            sheet.resultTab = 1
            try await settle(container.view) { outputPicker.selectedSegment == 1 }
            XCTAssertTrue(self.editor(in: container.view) === editor)
            sheet.resultTab = 0
            try await settle(container.view) { outputPicker.selectedSegment == 0 && self.table(in: container.view) != nil }
            XCTAssertTrue(table(in: container.view) === grid)
            XCTAssertEqual(grid.tableColumns[1].width, 600, accuracy: 0.1)
            XCTAssertEqual(grid.tableColumns[2].width, 560, accuracy: 0.1)
            XCTAssertEqual(grid.selectedRow, 80)
            XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        }
        await sheet.close()
    }

    func testInspectorRetainsItsOwnTextSelectionAcrossDetachedHosts() async throws {
        let model = makeModel()
        let first = model.active
        first.selectedColumn = "payload"
        first.selectedValue = (0..<300).map { "first payload line \($0)" }.joined(separator: "\n")
        model.addWorksheet()
        let second = model.active
        second.selectedColumn = "payload"
        second.selectedValue = "second payload"
        let hosts = QueryViewHosts()
        let container = QueryTabContentHost.Container()
        container.view.frame = NSRect(x: 0, y: 0, width: 360, height: 800)
        defer { container.clear(); hosts.prune(keeping: []) }
        model.showingInspector = true
        model.selectTab(first.id)
        let firstPage = hosts.page(for: first, model: model, kind: .inspector)
        container.show(firstPage, id: first.id, restoreFocus: false)
        try await settle(container.view) { !self.descendants(of: NSTextView.self, in: container.view).isEmpty }
        let text = try XCTUnwrap(descendants(of: NSTextView.self, in: container.view).first)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        text.setSelectedRange(NSRange(location: 10, length: 20))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(origin.y, 0)
        XCTAssertFalse(text.isEditable)
        XCTAssertEqual(first.inspectorSelection, NSRange(location: 10, length: 20))

        model.selectTab(second.id)
        container.show(hosts.page(for: second, model: model, kind: .inspector), id: second.id, restoreFocus: false)
        try await settle(container.view) { self.descendants(of: NSTextView.self, in: container.view).first?.string == second.selectedValue }
        model.selectTab(first.id)
        container.show(firstPage, id: first.id, restoreFocus: false)
        try await settle(container.view) { self.descendants(of: NSTextView.self, in: container.view).first === text }
        XCTAssertEqual(text.selectedRange(), NSRange(location: 10, length: 20))
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        await first.close()
        await second.close()
    }

    func testClosingAndPruningReleasesTheHostAndDismantlesNativeViews() async throws {
        let model = makeModel()
        let first = model.active
        try await seedResults(first)
        model.addWorksheet()
        let second = model.active
        model.selectTab(first.id)
        let hosts = QueryViewHosts()
        let container = QueryTabContentHost.Container()
        container.view.frame = NSRect(x: 0, y: 0, width: 940, height: 900)
        defer { container.clear(); hosts.prune(keeping: []) }
        var page: QueryViewHosts.Page? = hosts.page(for: first, model: model, kind: .worksheet)
        weak let releasedPage = page
        weak let releasedController = page?.controller
        try autoreleasepool {
            container.show(try XCTUnwrap(page), id: first.id, restoreFocus: false)
            container.view.layoutSubtreeIfNeeded()
        }
        try await settle(container.view) { self.editor(in: container.view) != nil && self.table(in: container.view) != nil }
        weak let releasedEditor = editor(in: container.view)
        weak let releasedGrid = table(in: container.view)
        XCTAssertNotNil(releasedEditor)
        XCTAssertNotNil(releasedGrid)
        page = nil

        let closed = await model.closeTab(id: first.id)
        XCTAssertTrue(closed)
        autoreleasepool {
            hosts.prune(keeping: Set(model.worksheets.map(\.id)))
            container.show(hosts.page(for: second, model: model, kind: .worksheet), id: second.id, restoreFocus: false)
            container.view.layoutSubtreeIfNeeded()
        }
        // AppKit may retain detached native views until a later autorelease or
        // drawing cycle. The app-owned host must release immediately, and its
        // native coordinators must already be dismantled even in that interval.
        try await settle(container.view) {
            releasedPage == nil && releasedController == nil && releasedEditor?.delegate == nil && releasedGrid?.delegate == nil
        }
        XCTAssertNil(releasedPage, "Query page must be released after pruning")
        XCTAssertNil(releasedController, "Query hosting controller must be released after pruning")
        XCTAssertNil(releasedEditor?.delegate, "Closed editor must stop its coordinator")
        XCTAssertNil(releasedGrid?.delegate, "Closed grid must stop its coordinator")
        XCTAssertNil(releasedGrid?.dataSource, "Closed grid must stop requesting data")
        XCTAssertFalse(releasedEditor?.undoManager?.canUndo ?? false)
        XCTAssertTrue(first.isClosed)
        await second.close()
    }

    private func makeModel() -> WorkbenchModel {
        WorkbenchModel(persistence: HostPersistence(), dialogs: HostDialogs(), worksheetFactory: { title in
            Worksheet(title: title, sessionFactory: { _ in DemoSession() })
        })
    }

    private func seedResults(_ sheet: Worksheet) async throws {
        let rows: [DatabaseRow] = (0..<500).map { [.text("row \($0)"), .text("result \($0)")] }
        _ = try await sheet.store.append(RowBatch(rows: rows))
        sheet.columns = [DatabaseColumn(index: 0, name: "id"), DatabaseColumn(index: 1, name: "name")]
        sheet.rowCount = rows.count
        sheet.revision += 1
    }

    private func editor(in view: NSView) -> NSTextView? { descendants(of: NSTextView.self, in: view).first { $0.isEditable } }
    private func table(in view: NSView) -> NSTableView? { descendants(of: NSTableView.self, in: view).first }
    private func cellText(_ table: NSTableView, row: Int) -> String? {
        (table.delegate?.tableView?(table, viewFor: table.tableColumns[1], row: row) as? NSTableCellView)?.textField?.stringValue
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func settle(_ view: NSView, until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        var stable = 0
        for _ in 0..<150 {
            autoreleasepool { view.layoutSubtreeIfNeeded() }
            stable = condition() ? stable + 1 : 0
            if stable >= 3 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Retained native host did not settle", file: file, line: line)
    }
}

private struct HostPersistence: WorkbenchPersistence {
    func loadProfiles() async throws -> [ConnectionProfile] { [] }
    func saveProfiles(_ profiles: [ConnectionProfile]) async throws { throw DatabaseError("Unexpected persistence in host test") }
    func password(for id: UUID) async throws -> String { throw DatabaseError("Unexpected credential lookup in host test") }
    func savePassword(_ password: String, for id: UUID) async throws { throw DatabaseError("Unexpected credential write in host test") }
    func readSQL(at url: URL) async throws -> String { throw DatabaseError("Unexpected file read in host test") }
    func writeSQL(_ sql: String, at url: URL) async throws { throw DatabaseError("Unexpected file write in host test") }
}

@MainActor
private struct HostDialogs: WorkbenchDialogs {
    func chooseOpenSQL() async -> URL? { XCTFail("Unexpected open dialog in host test"); return nil }
    func chooseSaveSQL(title: String, currentURL: URL?) async -> URL? { XCTFail("Unexpected save dialog in host test"); return nil }
    func chooseExportCSV() async -> URL? { XCTFail("Unexpected export dialog in host test"); return nil }
    func confirmClose(_ snapshot: WorksheetCloseSnapshot) async -> WorksheetCloseDecision { XCTFail("Unexpected close dialog in host test"); return .keepOpen }
}
