import AppKit
import XCTest
import DB3Core
@testable import DB3Grid

/// These views remain offscreen; no desktop or window is opened.
@MainActor
final class ResultChoiceEditorTests: XCTestCase {
    private func vocabulary(_ count: Int = 3) throws -> ValueChoiceSet {
        try ValueChoiceSet(choices: (0..<count).map { ValueChoice(key: "key\($0)", label: "Label \($0)", description: "Description \($0)") }, source: "Synthetic project", revision: "1")
    }
    func testSearchFindsOffscreenKeyAndSupersedesOldSearchWithoutChangingSelection() async throws {
        let model = ResultChoiceModel(choices: try vocabulary(900), original: .text("legacy"))
        defer { model.stop() }
        XCTAssertTrue(model.isUnknown); XCTAssertTrue(model.currentDescription.contains("preserved unchanged"))
        model.search("key8"); model.search("description 899")
        try await waitForSearch(model)
        XCTAssertEqual(model.indices, [899]); XCTAssertEqual(model.editedValue, .text("legacy"))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.editedValue, .text("key899"))
        model.search("no matches"); try await waitForSearch(model)
        XCTAssertTrue(model.indices.isEmpty); XCTAssertEqual(model.editedValue, .text("key899"))
    }

    func testNullUnknownAndEmptyKeepExactCurrentValueUntilUserChooses() throws {
        let choices = try ValueChoiceSet(choices: [.init(key: "", label: "Empty"), .init(key: "False", label: "Literal False")], source: "S", revision: "1")
        for original: DatabaseValue in [.null, .text(""), .text("False"), .text("old-key")] {
            let model = ResultChoiceModel(choices: choices, original: original)
            XCTAssertEqual(model.editedValue, original)
            model.select(row: 1); XCTAssertEqual(model.editedValue, .text("False"))
            model.select(row: 0); XCTAssertEqual(model.editedValue, .text("")); model.stop()
        }
    }

    func testUnicodeUnknownValueDoesNotSelectCanonicallyEquivalentKnownKey() throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let choices = try ValueChoiceSet(choices: [.init(key: composed, label: "Composed")], source: "S", revision: "1")
        let model = ResultChoiceModel(choices: choices, original: .text(decomposed))
        XCTAssertTrue(model.isUnknown); XCTAssertEqual(model.selectedRow, -1)
        XCTAssertEqual(model.editedValue, .text(decomposed))
        model.select(row: 0)
        XCTAssertEqual(model.editedValue, .text(composed)); XCTAssertNotEqual(model.editedValue, .text(decomposed))
        model.stop()
    }

    func testNativePopoverAndSheetShareModelWithKeyboardAndAccessibleKeys() throws {
        let small = ResultChoiceEditor(GridCellEdit(value: .text("key0"), nullable: true, label: "Status"), choices: try vocabulary())
        _ = small.view; defer { small.stop() }
        XCTAssertFalse(small.usesSheet)
        let cell = try XCTUnwrap(small.tableView(small.table, viewFor: small.table.tableColumns[0], row: 0))
        XCTAssertTrue(cell.accessibilityLabel()?.contains("stored key key0") == true)
        XCTAssertTrue(cell.accessibilityLabel()?.contains("current value") == true)
        var staged: [DatabaseValue] = []; var canceled = 0
        small.onStage = { staged.append($0) }; small.onCancel = { canceled += 1 }
        let fieldEditor = NSTextView()
        XCTAssertTrue(small.control(small.searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(staged.isEmpty)
        XCTAssertTrue(small.control(small.searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(staged, [.text("key1")])
        _ = small.control(small.searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(canceled, 1)
        let large = ResultChoiceEditor(GridCellEdit(value: .null, label: "Status"), choices: try vocabulary(500))
        _ = large.view; defer { large.stop() }
        XCTAssertTrue(large.usesSheet); XCTAssertEqual(large.numberOfRows(in: large.table), 200)
        XCTAssertTrue(large.model.resultDescription.contains("Refine"))
    }

    func testGridChoiceStagingPreservesCapturedVocabularyAndUnknownRawFallback() async throws {
        let fixture = try ChoiceGridFixture(choices: vocabulary(), original: .text("unknown"))
        let grid = fixture.grid(), coordinator = grid.makeCoordinator()
        let scroll = grid.makeScrollView(coordinator: coordinator)
        defer { ResultsGrid.dismantleNSView(scroll, coordinator: coordinator) }
        coordinator.beginEditing(row: 0, column: 0)
        let editor = try await waitForEditor(coordinator)
        XCTAssertTrue(fixture.staged.isEmpty); XCTAssertTrue(editor.model.isUnknown)
        fixture.choices = try vocabulary(500)
        coordinator.update(parent: fixture.grid())
        XCTAssertEqual(editor.model.choices.choices.count, 3, "The open editor retains its captured source revision.")
        try await fixture.controller.finish()
        XCTAssertTrue(fixture.staged.isEmpty, "Finishing untouched unknown values never substitutes a known choice.")
        coordinator.beginEditing(row: 0, column: 0)
        let second = try await waitForEditor(coordinator)
        second.model.select(row: 2)
        XCTAssertTrue(fixture.staged.isEmpty)
        try await fixture.controller.finish()
        XCTAssertEqual(fixture.staged, [.text("key2")])
        coordinator.beginEditing(row: 0, column: 0)
        let third = try await waitForEditor(coordinator)
        third.onRawValue?()
        XCTAssertNil(coordinator.choiceEditor)
        let input = try XCTUnwrap((scroll.documentView as? NSTableView)?.subviews.compactMap { $0 as? ResultEditingField }.first)
        XCTAssertEqual(input.stringValue, "unknown")
        fixture.controller.cancel()
        XCTAssertFalse(fixture.controller.hasActiveEditor)
    }

    private func waitForSearch(_ model: ResultChoiceModel) async throws {
        for _ in 0..<200 { if !model.searching { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Choice search did not complete")
    }
    private func waitForEditor(_ coordinator: ResultsGrid.Coordinator) async throws -> ResultChoiceEditor {
        for _ in 0..<200 { if let editor = coordinator.choiceEditor { return editor }; try await Task.sleep(for: .milliseconds(5)) }
        throw DatabaseError("Choice editor did not become ready")
    }
}

@MainActor private final class ChoiceGridFixture {
    let controller = ResultsGridEditorController()
    var choices: ValueChoiceSet
    let original: DatabaseValue
    var staged: [DatabaseValue] = []
    init(choices: ValueChoiceSet, original: DatabaseValue) { self.choices = choices; self.original = original }
    func grid() -> ResultsGrid {
        ResultsGrid(columns: [DatabaseColumn(index: 0, name: "status")], rowCount: 1, revision: 0,
            loadRows: { _ in [[.text("preview")]] }, editing: ResultsGridEditing(revision: 0, controller: controller,
                load: { [self] _, _ in GridCellEdit(value: original, nullable: true, label: "Status", choices: choices) },
                stage: { [self] _, _, value in staged.append(value) }, onError: { XCTFail($0) }))
    }
}
