import AppKit
import SwiftUI
import XCTest
@testable import DB3Editor

/// Native views only: no windows, first-responder changes, or computer control.
@MainActor
final class SQLTextEditorLifetimeTests: XCTestCase {
    func testIndependentUndoManagersSurviveRepeatedActivation() async throws {
        let first = EditorDocument(text: "SELECT 1;")
        let second = EditorDocument(text: "SELECT 2;")
        let firstView = first.view()
        let secondView = second.view(isActive: false)
        let firstCoordinator = firstView.makeCoordinator()
        let secondCoordinator = secondView.makeCoordinator()
        let firstScroll = firstView.makeScrollView(coordinator: firstCoordinator)
        let secondScroll = secondView.makeScrollView(coordinator: secondCoordinator)
        defer {
            SQLTextEditor.dismantleNSView(firstScroll, coordinator: firstCoordinator)
            SQLTextEditor.dismantleNSView(secondScroll, coordinator: secondCoordinator)
        }
        let firstEditor = try XCTUnwrap(firstScroll.documentView as? NSTextView)
        let secondEditor = try XCTUnwrap(secondScroll.documentView as? NSTextView)
        let firstUndo = try XCTUnwrap(firstEditor.undoManager)
        let secondUndo = try XCTUnwrap(secondEditor.undoManager)
        XCTAssertFalse(firstUndo === secondUndo)

        insert(" -- first", in: firstEditor)
        insert(" -- second", in: secondEditor)
        XCTAssertEqual(first.text, "SELECT 1; -- first")
        XCTAssertEqual(second.text, "SELECT 2; -- second")
        let firstSelection = firstEditor.selectedRange()
        let secondSelection = secondEditor.selectedRange()
        for _ in 0..<8 {
            firstCoordinator.update(parent: first.view(isActive: false))
            secondCoordinator.update(parent: second.view())
            secondCoordinator.update(parent: second.view(isActive: false))
            firstCoordinator.update(parent: first.view())
        }
        XCTAssertTrue(firstScroll.documentView === firstEditor)
        XCTAssertTrue(secondScroll.documentView === secondEditor)
        XCTAssertEqual(firstEditor.selectedRange(), firstSelection)
        XCTAssertEqual(secondEditor.selectedRange(), secondSelection)
        XCTAssertTrue(firstEditor.undoManager === firstUndo)
        XCTAssertTrue(secondEditor.undoManager === secondUndo)

        firstUndo.undo()
        XCTAssertEqual(firstEditor.string, "SELECT 1;")
        XCTAssertEqual(first.text, "SELECT 1;")
        XCTAssertEqual(second.text, "SELECT 2; -- second")
        XCTAssertTrue(secondUndo.canUndo)
        firstUndo.redo()
        XCTAssertEqual(first.text, "SELECT 1; -- first")
        secondUndo.undo()
        XCTAssertEqual(secondEditor.string, "SELECT 2;")
        XCTAssertEqual(second.text, "SELECT 2;")
        XCTAssertEqual(first.text, "SELECT 1; -- first")
    }

    func testSelectionAndViewportSurviveActivation() throws {
        let document = EditorDocument(text: String(repeating: "SELECT 'retained document';\n", count: 150))
        let view = document.view()
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        defer { SQLTextEditor.dismantleNSView(scroll, coordinator: coordinator) }
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 250)
        editor.frame = NSRect(x: 0, y: 0, width: 1000, height: 3000)
        scroll.tile()
        editor.setSelectedRange(NSRange(location: 300, length: 12))
        scroll.contentView.scroll(to: NSPoint(x: 70, y: 650))
        scroll.reflectScrolledClipView(scroll.contentView)
        let selection = editor.selectedRange()
        let viewport = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(viewport.y, 0)

        coordinator.update(parent: document.view(isActive: false))
        coordinator.update(parent: document.view())
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(scroll.contentView.bounds.origin, viewport)
        XCTAssertEqual(document.selection, selection)
    }

    func testDocumentLoadResetsUndoButTypingRoundtripDoesNot() throws {
        let document = EditorDocument(text: "SELECT 1;")
        let view = document.view()
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        defer { SQLTextEditor.dismantleNSView(scroll, coordinator: coordinator) }
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        let undo = try XCTUnwrap(editor.undoManager)
        insert(" -- edit", in: editor)
        coordinator.update(parent: document.view())
        XCTAssertTrue(undo.canUndo)
        document.text = "SELECT 'loaded';"
        document.selection = NSRange(location: 0, length: 0)
        coordinator.update(parent: document.view())
        XCTAssertEqual(editor.string, document.text)
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        insert(" -- new edit", in: editor)
        undo.undo()
        XCTAssertEqual(editor.string, "SELECT 'loaded';")
        XCTAssertEqual(document.text, "SELECT 'loaded';")
    }

    func testInactiveAndDismantledEditorDoesNotHighlight() async throws {
        let document = EditorDocument(text: "SELECT 42;")
        let view = document.view()
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        let storage = try XCTUnwrap(editor.textStorage)
        let before = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        coordinator.update(parent: document.view(isActive: false))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, before)

        coordinator.update(parent: document.view())
        for _ in 0..<50 {
            if (storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .systemPurple { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemPurple)
        XCTAssertFalse(try XCTUnwrap(editor.undoManager).canUndo, "Highlighting is not a document edit.")

        document.text = "UPDATE example SET value = 3;"
        coordinator.update(parent: document.view())
        let resetColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        SQLTextEditor.dismantleNSView(scroll, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, resetColor)
        XCTAssertNil(editor.delegate)
        XCTAssertFalse(try XCTUnwrap(editor.undoManager).canUndo)
    }

    func testActivationDoesNotReplaceMarkedText() throws {
        let document = EditorDocument(text: "SELECT ")
        let view = document.view()
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        defer { SQLTextEditor.dismantleNSView(scroll, coordinator: coordinator) }
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let markedText = editor.string
        let markedRange = editor.markedRange()
        coordinator.update(parent: document.view(isActive: false))
        coordinator.update(parent: document.view())
        XCTAssertEqual(editor.string, markedText)
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()
    }

    private func insert(_ text: String, in editor: NSTextView) {
        let undo = editor.undoManager!
        undo.groupsByEvent = false
        editor.breakUndoCoalescing()
        undo.beginUndoGrouping()
        editor.insertText(text, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
    }
}

@MainActor
private final class EditorDocument {
    var text: String
    var selection = NSRange(location: 0, length: 0)
    init(text: String) { self.text = text }

    func view(isActive: Bool = true) -> SQLTextEditor {
        SQLTextEditor(
            text: Binding(get: { self.text }, set: { self.text = $0 }),
            selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
            isActive: isActive
        )
    }
}
