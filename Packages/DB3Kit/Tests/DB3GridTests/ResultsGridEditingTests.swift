import AppKit
import XCTest
import DB3Core
@testable import DB3Grid

/// Every native view stays offscreen; these tests never control the desktop.
@MainActor
final class ResultsGridEditingTests: XCTestCase {
    func testExactLoaderValueNotTilePreviewStartsEditorAndStagesOnlyOnFinish() async throws {
        let fixture = EditingFixture()
        fixture.original = .text("exact value from snapshot")
        let native = fixture.attach()
        defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        XCTAssertEqual(field.stringValue, "exact value from snapshot")
        XCTAssertEqual(fixture.loaded, [0])
        XCTAssertTrue(fixture.staged.isEmpty)
        XCTAssertTrue(fixture.controller.hasActiveEditor)
        field.stringValue = "new value"
        native.coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await fixture.controller.finish()
        XCTAssertEqual(fixture.staged, [.text("new value")])
        XCTAssertFalse(fixture.controller.hasActiveEditor)
    }

    func testUntouchedNullStaysNullAndExplicitEmptyTextIsDistinct() async throws {
        let fixture = EditingFixture(); fixture.original = .null; fixture.nullable = true
        let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        _ = try await waitForField(native)
        try await fixture.controller.finish()
        XCTAssertTrue(fixture.staged.isEmpty)

        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        native.coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await fixture.controller.finish()
        XCTAssertEqual(fixture.staged, [.text("")])
    }

    func testSetNullAndEmptyTextDoNotCollapseZeroFalseOrLiteralNull() async throws {
        for source in ["0", "false", "NULL", ""] {
            let fixture = EditingFixture(); fixture.original = .text(source); fixture.nullable = true
            let native = fixture.attach()
            native.coordinator.beginEditing(row: 0, column: 0)
            _ = try await waitForField(native)
            try await native.coordinator.finishEditor(replacement: .null)
            XCTAssertEqual(fixture.staged, [.null])
            native.stop()
        }
    }

    func testCancelDropsOnlyActiveValueAndDoesNotStage() async throws {
        let fixture = EditingFixture(); let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        field.stringValue = "not staged"
        fixture.controller.cancel()
        XCTAssertTrue(fixture.staged.isEmpty)
        XCTAssertFalse(fixture.controller.hasActiveEditor)
        XCTAssertNil(field.superview)
    }

    func testValidationErrorKeepsValueAndActiveEditorForCorrection() async throws {
        let fixture = EditingFixture(); fixture.reject = true
        let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        field.stringValue = "invalid integer"
        do { try await fixture.controller.finish(); XCTFail("Expected validation rejection") } catch {}
        XCTAssertTrue(fixture.controller.hasActiveEditor)
        XCTAssertEqual(field.stringValue, "invalid integer")
        XCTAssertTrue(fixture.staged.isEmpty)
    }

    func testReadOnlyCellExplainsReasonWithoutLoadingValue() async throws {
        let fixture = EditingFixture(); fixture.reason = "Primary-key columns cannot be changed."
        let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        XCTAssertEqual(fixture.errors, [fixture.reason!])
        XCTAssertTrue(fixture.loaded.isEmpty)
        XCTAssertFalse(fixture.controller.hasActiveEditor)
    }

    func testInactiveTabKeepsPendingFieldWithoutStagingAndReactivatesIt() async throws {
        let fixture = EditingFixture(); let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        field.stringValue = "typing survives switching tabs"
        native.coordinator.update(parent: fixture.grid(active: false))
        XCTAssertTrue(fixture.controller.hasActiveEditor)
        XCTAssertTrue(fixture.staged.isEmpty)
        native.coordinator.update(parent: fixture.grid(active: true))
        XCTAssertTrue(field.superview === native.table)
        XCTAssertEqual(field.stringValue, "typing survives switching tabs")
        try await fixture.controller.finish()
        XCTAssertEqual(fixture.staged, [.text("typing survives switching tabs")])
    }

    func testOverlayRefreshChangesPresentationWithoutReplacingEditorOrResizingColumn() async throws {
        let fixture = EditingFixture(); let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        field.stringValue = "in progress"
        native.table.tableColumns[1].width = 200
        fixture.overlay = .text("draft overlay")
        native.coordinator.update(parent: fixture.grid(overlayRevision: 1))
        let cell = native.coordinator.tableView(native.table, viewFor: native.table.tableColumns[1], row: 0) as? NSTableCellView
        XCTAssertEqual(cell?.textField?.stringValue, "draft overlay")
        XCTAssertTrue(field.superview === native.table)
        XCTAssertEqual(field.stringValue, "in progress")
        XCTAssertEqual(native.table.tableColumns[1].width, 200, accuracy: 0.1)
    }

    func testLateExactValueFromReplacedResultCannotCreateEditor() async throws {
        let pending = PendingGridValue()
        let fixture = EditingFixture()
        var reservations = 0
        fixture.reserveEditor = { reservations += 1; return NSObject() }
        fixture.loadOverride = { await pending.value() }
        let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        for _ in 0..<100 {
            if await pending.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        native.coordinator.update(parent: fixture.grid(resultRevision: 1))
        await pending.resume(.text("old source"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(fixture.controller.hasActiveEditor)
        XCTAssertTrue(native.table.subviews.compactMap { $0 as? ResultEditingField }.isEmpty)
        XCTAssertTrue(fixture.staged.isEmpty)
        XCTAssertEqual(reservations, 0)
    }

    func testEditorPayloadLeaseReleasesOnStageCancelAndResultReplacement() async throws {
        let fixture = EditingFixture()
        weak var lease: NSObject?
        fixture.reserveEditor = { let object = NSObject(); lease = object; return object }
        let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        _ = try await waitForField(native)
        XCTAssertNotNil(lease)
        fixture.controller.cancel()
        XCTAssertNil(lease)

        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        field.stringValue = "staged"
        XCTAssertNotNil(lease)
        try await fixture.controller.finish()
        XCTAssertEqual(fixture.staged, [.text("staged")])
        XCTAssertNil(lease)

        native.coordinator.beginEditing(row: 0, column: 0)
        _ = try await waitForField(native)
        XCTAssertNotNil(lease)
        native.coordinator.update(parent: fixture.grid(resultRevision: 1))
        XCTAssertNil(lease)
    }

    func testComputedAnnotationRemainsVisibleAndAccessibleWithLocalDraftMarker() async throws {
        let fixture = EditingFixture()
        fixture.overlay = .text("local draft")
        fixture.annotation = "Computed field invoice.total · Project source"
        let native = fixture.attach(); defer { native.stop() }
        let cell = try XCTUnwrap(native.coordinator.tableView(native.table, viewFor: native.table.tableColumns[1], row: 0))
        XCTAssertTrue(cell.toolTip?.contains("Computed field invoice.total") == true)
        let labels = cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("ƒ•"))
        XCTAssertTrue(cell.accessibilityHelp()?.contains("Changed locally") == true)
    }

    func testExactValueBudgetAndAutomaticMultilineChoice() throws {
        XCTAssertThrowsError(try GridEditorValue.validate(GridCellEdit(value: .text(String(repeating: "a", count: 1_024 * 1_024)), label: "Too large")))
        let multiline = try GridEditorValue.validate(GridCellEdit(value: .text("first\nsecond"), label: "Notes"))
        XCTAssertEqual(multiline.kind, .multiline)
        let decimal = "123456789012345678901234567890.012345678900000000000001"
        let exact = try GridEditorValue.validate(GridCellEdit(value: .text(decimal), label: "Amount"))
        XCTAssertEqual(exact.value, .text(decimal))
        XCTAssertEqual(exact.kind, .scalar)
    }

    func testPopoverNullDoesNotChangeUntilTypedAndBooleanChoiceKeepsExactMeaning() throws {
        let nullable = try GridEditorValue.validate(GridCellEdit(value: .null, kind: .multiline, nullable: true, label: "Notes"))
        let view = ResultValuePopover(nullable); _ = view.view
        XCTAssertEqual(view.editedValue, .null)
        view.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertEqual(view.editedValue, .text(""))
        let boolean = ResultValuePopover(try GridEditorValue.validate(GridCellEdit(value: .text("f"), kind: .boolean, label: "Enabled")))
        _ = boolean.view
        XCTAssertEqual(boolean.editedValue, .text("f"))
        boolean.boolean.selectItem(at: 1); boolean.booleanChanged()
        XCTAssertEqual(boolean.editedValue, .text("true"))
    }

    func testBlankInsertRowCreatesLocalDraftAndRoutesGeneratedColumnToWritableEditor() async throws {
        let fixture = EditingFixture()
        fixture.rowCount = 0; fixture.additionalRows = 1; fixture.insertionRow = 0
        fixture.columns = [DatabaseColumn(index: 0, name: "generated_id"), DatabaseColumn(index: 1, name: "name")]
        fixture.original = .null; fixture.usesDefault = true; fixture.canUseDefault = true
        fixture.reason = "Generated values are read only."
        fixture.insert = { [weak fixture] column in
            guard let fixture else { throw CancellationError() }
            fixture.insertedColumns.append(column)
            fixture.reason = nil
            fixture.insertionRow = 1; fixture.additionalRows = 2
            return 1
        }
        let native = fixture.attach(); defer { native.stop() }
        XCTAssertEqual(native.coordinator.numberOfRows(in: native.table), 1)
        let gutter = native.coordinator.tableView(native.table, viewFor: native.table.tableColumns[0], row: 0) as? NSTableCellView
        XCTAssertEqual(gutter?.textField?.stringValue, "+")
        let blank = native.coordinator.tableView(native.table, viewFor: native.table.tableColumns[1], row: 0) as? NSTableCellView
        XCTAssertEqual(blank?.textField?.stringValue, "")
        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        XCTAssertEqual(fixture.insertedColumns, [0])
        XCTAssertEqual(fixture.loadedColumns, [1])
        XCTAssertEqual(field.placeholderString, "DEFAULT")
        native.coordinator.update(parent: fixture.grid(overlayRevision: 1))
        XCTAssertEqual(native.coordinator.numberOfRows(in: native.table), 2)
        try await fixture.controller.finish()
        XCTAssertTrue(fixture.staged.isEmpty)
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testUntouchedDefaultIsOmittedButExplicitNullAndEmptyTextAreStaged() async throws {
        let fixture = EditingFixture()
        fixture.original = .null; fixture.nullable = true; fixture.usesDefault = true
        let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        _ = try await waitForField(native)
        try await fixture.controller.finish()
        XCTAssertTrue(fixture.staged.isEmpty)
        native.coordinator.beginEditing(row: 0, column: 0)
        _ = try await waitForField(native)
        try await native.coordinator.finishEditor(replacement: .null)
        XCTAssertEqual(fixture.staged, [.null])
        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native)
        native.coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await fixture.controller.finish()
        XCTAssertEqual(fixture.staged, [.null, .text("")])
    }

    func testExplicitNullCannotReplaceNonnullableDefault() async throws {
        let fixture = EditingFixture(); fixture.original = .null; fixture.usesDefault = true
        let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        _ = try await waitForField(native)
        do { try await native.coordinator.finishEditor(replacement: .null); XCTFail("Expected NULL rejection") } catch {}
        XCTAssertTrue(fixture.staged.isEmpty)
        XCTAssertTrue(fixture.controller.hasActiveEditor)
        try await fixture.controller.finish()
        XCTAssertFalse(fixture.controller.hasActiveEditor)
    }

    func testSyntheticRowsNeverLoadOrInspectSnapshotValues() async throws {
        let reads = GridReadRanges()
        let fixture = EditingFixture()
        fixture.additionalRows = 100; fixture.insertionRow = 100
        fixture.overlay = .text("local only")
        fixture.loadRowsOverride = { range in await reads.record(range); return range.map { _ in [.text("stored")] } }
        let native = fixture.attach(); defer { native.stop() }
        for row in [1, 65, 100] {
            _ = native.coordinator.tableView(native.table, viewFor: native.table.tableColumns[1], row: row)
            native.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        native.table.scrollRowToVisible(100)
        try await Task.sleep(for: .milliseconds(50))
        let ranges = await reads.ranges
        XCTAssertTrue(ranges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= 1 })
        XCTAssertTrue(fixture.inspectedRows.isEmpty)
        XCTAssertTrue(fixture.loaded.isEmpty)
    }

    func testInsertWaitsForExistingEditorValidationBeforeCreatingDraft() async throws {
        let fixture = EditingFixture()
        fixture.additionalRows = 1; fixture.insertionRow = 1; fixture.reject = true
        fixture.insert = { [weak fixture] column in fixture?.insertedColumns.append(column); return column }
        let native = fixture.attach(); defer { native.stop() }
        native.coordinator.beginEditing(row: 0, column: 0)
        let field = try await waitForField(native); field.stringValue = "invalid"
        native.coordinator.beginEditing(row: 1, column: 0)
        for _ in 0..<100 {
            if !fixture.errors.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.errors, ["Not an integer"])
        XCTAssertTrue(fixture.insertedColumns.isEmpty)
        XCTAssertTrue(fixture.controller.hasActiveEditor)
    }

    func testLateInsertCompletionCannotOpenEditorAfterStopping() async throws {
        let pending = PendingGridValue()
        let fixture = EditingFixture(); fixture.rowCount = 0; fixture.additionalRows = 1; fixture.insertionRow = 0
        fixture.insert = { _ in _ = await pending.value(); return 0 }
        let native = fixture.attach()
        native.coordinator.beginEditing(row: 0, column: 0)
        for _ in 0..<100 {
            if await pending.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        native.stop()
        await pending.resume(.null)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.loaded.isEmpty)
        XCTAssertFalse(fixture.controller.hasActiveEditor)
    }

    private func waitForField(_ native: NativeEditingFixture) async throws -> ResultEditingField {
        for _ in 0..<100 {
            if let field = native.table.subviews.compactMap({ $0 as? ResultEditingField }).first { return field }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DatabaseError("Native field editor did not become ready.")
    }
}

@MainActor
private final class EditingFixture {
    let controller = ResultsGridEditorController()
    var original: DatabaseValue = .text("original")
    var nullable = false
    var usesDefault = false
    var canUseDefault = false
    var rowCount = 1
    var columns = [DatabaseColumn(index: 0, name: "name")]
    var additionalRows = 0
    var insertionRow: Int?
    var insert: (@MainActor (Int) async throws -> Int)?
    var insertedColumns: [Int] = []
    var loadedColumns: [Int] = []
    var inspectedRows: [Int] = []
    var loadRowsOverride: (@Sendable (Range<Int>) async throws -> [DatabaseRow])?
    var reason: String?
    var overlay: DatabaseValue?
    var annotation: String?
    var reject = false
    var loaded: [Int] = []
    var staged: [DatabaseValue] = []
    var errors: [String] = []
    var loadOverride: (@MainActor () async -> DatabaseValue)?
    var reserveEditor: (@MainActor () throws -> AnyObject)?

    func grid(active: Bool = true, resultRevision: Int = 0, overlayRevision: Int = 0) -> ResultsGrid {
        ResultsGrid(columns: columns, rowCount: rowCount, revision: resultRevision, isActive: active,
            loadRows: loadRowsOverride ?? { _ in [[.text("truncated tile preview")]] },
            onSelect: { [self] row, _, _ in inspectedRows.append(row) }, editing: ResultsGridEditing(
                revision: overlayRevision, controller: controller,
                presentation: { [self] _, _ in GridCellPresentation(value: overlay, isChanged: overlay != nil, readOnlyReason: reason, annotation: annotation) },
                load: { [self] row, column in
                    loaded.append(row)
                    loadedColumns.append(column)
                    let value = if let loadOverride { await loadOverride() } else { original }
                    return GridCellEdit(value: value, nullable: nullable, label: "name", usesDefault: usesDefault, canUseDefault: canUseDefault)
                },
                stage: { [self] _, _, value in
                    if reject { throw DatabaseError("Not an integer") }
                    staged.append(value)
                }, reserveEditor: reserveEditor, onError: { [self] in errors.append($0) },
                additionalRowCount: additionalRows, insertionRow: insertionRow, insert: insert
            ))
    }
    func attach() -> NativeEditingFixture {
        let grid = grid(); let coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 480, height: 300); scroll.tile()
        return NativeEditingFixture(scroll: scroll, coordinator: coordinator, table: scroll.documentView as! NSTableView)
    }
}

@MainActor
private struct NativeEditingFixture {
    let scroll: NSScrollView
    let coordinator: ResultsGrid.Coordinator
    let table: NSTableView
    func stop() { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
}

private actor PendingGridValue {
    private var continuation: CheckedContinuation<DatabaseValue, Never>?
    private(set) var started = false
    func value() async -> DatabaseValue {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume(_ value: DatabaseValue) { continuation?.resume(returning: value); continuation = nil }
}

private actor GridReadRanges {
    private(set) var ranges: [Range<Int>] = []
    func record(_ range: Range<Int>) { ranges.append(range) }
}
