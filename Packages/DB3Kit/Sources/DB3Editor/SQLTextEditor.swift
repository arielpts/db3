import AppKit
import SwiftUI

/// A native TextKit 2 SQL editor. Text changes retain AppKit's undo, selection,
/// marked-text, find, and accessibility behavior instead of rebuilding the view.
@MainActor
public struct SQLTextEditor: NSViewRepresentable {
    @Binding private var text: String
    @Binding private var selection: NSRange
    private let fontSize: CGFloat
    private let isEditable: Bool
    private let isActive: Bool

    public init(text: Binding<String>, selection: Binding<NSRange>, fontSize: CGFloat = 13, isEditable: Bool = true, isActive: Bool = true) {
        _text = text
        _selection = selection
        self.fontSize = fontSize
        self.isEditable = isEditable
        self.isActive = isActive
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    /// Kept separate from the SwiftUI context so native document lifetime can be
    /// verified in offscreen tests without opening a window.
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder

        let editor = SQLDocumentTextView(usingTextLayoutManager: true)
        editor.isEditable = isEditable
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = isEditable
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = NSSize(width: 16, height: 14)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(isEditable ? "SQL worksheet" : "Result value")
        editor.setAccessibilityHelp("Run executes the statement at the cursor. Highlight SQL to execute that selection instead.")
        editor.string = text
        editor.setSelectedRange(clampedSelection(selection, length: editor.textStorage?.length ?? 0))
        editor.delegate = coordinator
        scroll.documentView = editor
        coordinator.attach(editor: editor, scroll: scroll)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    public static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
        (view.documentView as? NSTextView)?.delegate = nil
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var parent: SQLTextEditor
        fileprivate var lastPublishedText: String
        fileprivate var revision = 0
        fileprivate var isApplyingExternalChange = false
        private weak var editor: NSTextView?
        private weak var clipView: NSClipView?
        private var debounce: Task<Void, Never>?
        private var syntaxTask: Task<[SQLToken], Never>?
        private var changedLocation: Int?
        private var highlightedRevision = -1
        private var highlightedRange = NSRange(location: 0, length: 0)
        private var isStopped = false

        fileprivate init(parent: SQLTextEditor) {
            self.parent = parent
            lastPublishedText = parent.text
        }

        fileprivate func attach(editor: NSTextView, scroll: NSScrollView) {
            self.editor = editor
            clipView = scroll.contentView
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            // A document-owned manager can undo native text storage without
            // sending textDidChange through a window's text editing machinery.
            // Publish after either undo path so SQL and dirty state stay current.
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoCompleted), name: .NSUndoManagerDidUndoChange, object: editor.undoManager)
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoCompleted), name: .NSUndoManagerDidRedoChange, object: editor.undoManager)
            scheduleHighlight()
        }

        fileprivate func stop() {
            isStopped = true
            debounce?.cancel()
            syntaxTask?.cancel()
            editor?.undoManager?.removeAllActions()
            NotificationCenter.default.removeObserver(self)
        }

        func update(parent: SQLTextEditor) {
            let activityChanged = self.parent.isActive != parent.isActive || self.parent.isEditable != parent.isEditable
            self.parent = parent
            guard !isStopped, let editor else { return }
            editor.isEditable = parent.isEditable
            editor.allowsUndo = parent.isEditable
            // The typing roundtrip matches lastPublishedText and leaves native
            // text storage and undo untouched. A different String is an explicit
            // document load/reset, whose prior undo history must not survive.
            if parent.text != lastPublishedText, !editor.hasMarkedText() {
                isApplyingExternalChange = true
                editor.breakUndoCoalescing()
                editor.undoManager?.removeAllActions()
                editor.string = parent.text
                editor.undoManager?.removeAllActions()
                lastPublishedText = parent.text
                revision &+= 1
                editor.setSelectedRange(clampedSelection(parent.selection, length: editor.textStorage?.length ?? 0))
                isApplyingExternalChange = false
                scheduleHighlight()
            }
            if !editor.hasMarkedText() {
                let range = clampedSelection(parent.selection, length: editor.textStorage?.length ?? 0)
                if editor.selectedRange() != range { editor.setSelectedRange(range) }
            }
            if editor.font?.pointSize != parent.fontSize {
                editor.font = .monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            }
            if activityChanged { scheduleHighlight() }
        }

        public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            changedLocation = affectedCharRange.location
            return true
        }

        public func textDidChange(_ notification: Notification) {
            guard !isStopped, !isApplyingExternalChange, let editor else { return }
            guard editor.string != lastPublishedText else { return }
            revision &+= 1
            // One plain String is the document model. Attributed text and token
            // arrays are never copied into observable state.
            lastPublishedText = editor.string
            parent.text = lastPublishedText
            parent.selection = editor.selectedRange()
            scheduleHighlight()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isStopped, !isApplyingExternalChange, let editor else { return }
            let selection = editor.selectedRange()
            if parent.selection != selection { parent.selection = selection }
        }

        @objc private func viewportChanged(_ notification: Notification) { scheduleHighlight() }
        @objc private func undoOrRedoCompleted(_ notification: Notification) { textDidChange(notification) }

        fileprivate func scheduleHighlight() {
            debounce?.cancel()
            syntaxTask?.cancel()
            debounce = nil
            syntaxTask = nil
            guard !isStopped, parent.isEditable, parent.isActive else { return }
            debounce = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                guard let self, !self.isStopped, self.parent.isActive,
                      let editor = self.editor, !editor.hasMarkedText(), let storage = editor.textStorage else { return }
                // Huge documents remain editable, with plain text and deferred
                // analysis. Even ordinary highlighting copies at most 24 Ki UTF-16.
                guard storage.length > 0, storage.length <= 2 * 1_024 * 1_024 else { return }
                let visible = editor.visibleRect
                let top = editor.characterIndexForInsertion(at: NSPoint(x: visible.minX + 2, y: visible.minY + 2))
                let bottom = editor.characterIndexForInsertion(at: NSPoint(x: visible.maxX - 2, y: visible.maxY - 2))
                let anchor = self.changedLocation ?? min(top, storage.length)
                self.changedLocation = nil
                let start = max(0, min(anchor, storage.length) - 1_024)
                let end = min(storage.length, max(start + 4_096, min(bottom + 1_024, start + 24_576)))
                let range = NSRange(location: start, length: end - start)
                let currentRevision = self.revision
                if self.highlightedRevision == currentRevision,
                   NSLocationInRange(anchor, self.highlightedRange),
                   NSMaxRange(range) <= NSMaxRange(self.highlightedRange) { return }
                let source = (storage.string as NSString).substring(with: range)
                let work = Task.detached(priority: .utility) { SQLLexer.tokens(in: source) }
                self.syntaxTask = work
                let tokens = await work.value
                guard !Task.isCancelled, !work.isCancelled,
                      !self.isStopped, self.parent.isActive,
                      self.revision == currentRevision, !editor.hasMarkedText(),
                      NSMaxRange(range) <= storage.length else { return }
                // Attribute-only edits are bounded and never change characters or
                // enter the text view's native undo stack.
                storage.beginEditing()
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                for token in tokens {
                    let tokenRange = NSRange(location: range.location + token.range.location, length: token.range.length)
                    storage.addAttribute(.foregroundColor, value: token.kind.color, range: tokenRange)
                }
                storage.endEditing()
                editor.typingAttributes[.foregroundColor] = NSColor.textColor
                self.highlightedRevision = currentRevision
                self.highlightedRange = range
            }
        }
    }
}

/// NSTextView normally inherits the window's undo manager. Retained tabs share
/// a window but are different documents, so each editor supplies its own manager
/// to AppKit's ordinary responder-chain undo/redo commands.
@MainActor
private final class SQLDocumentTextView: NSTextView {
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
}

private func clampedSelection(_ range: NSRange, length: Int) -> NSRange {
    let start = min(max(0, range.location), length)
    return NSRange(location: start, length: min(max(0, range.length), length - start))
}

private struct SQLToken: Sendable {
    enum Kind: Sendable {
        case keyword, string, number, comment
        @MainActor var color: NSColor {
            switch self {
            case .keyword: .systemPurple
            case .string: .systemRed
            case .number: .systemBlue
            case .comment: .secondaryLabelColor
            }
        }
    }
    let range: NSRange
    let kind: Kind
}

/// A lightweight lexical colorizer, not a SQL parser or statement splitter.
/// Bounded viewport snippets may start inside a multiline token; execution never
/// uses these tokens to choose or transform the SQL that reaches PostgreSQL.
private enum SQLLexer {
    static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IS", "AS", "IN", "ON", "BY", "ORDER", "GROUP", "HAVING", "LIMIT", "OFFSET", "DISTINCT", "JOIN", "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS", "LATERAL", "UNION", "ALL", "EXCEPT", "INTERSECT", "WITH", "RECURSIVE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING", "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "INDEX", "FUNCTION", "PROCEDURE", "SCHEMA", "BEGIN", "END", "COMMIT", "ROLLBACK", "SAVEPOINT", "CASE", "WHEN", "THEN", "ELSE", "TRUE", "FALSE", "EXISTS", "BETWEEN", "LIKE", "ILIKE", "ASC", "DESC", "NULLS", "FIRST", "LAST", "EXPLAIN", "ANALYZE", "OVER", "PARTITION", "FILTER", "DO", "LANGUAGE", "DECLARE", "IF", "LOOP", "RAISE", "PERFORM", "EXECUTE", "RETURNS"
    ]

    static func tokens(in text: String) -> [SQLToken] {
        let units = Array(text.utf16)
        var result: [SQLToken] = []
        var cursor = 0
        func isLetter(_ value: UInt16) -> Bool { (65...90).contains(value) || (97...122).contains(value) || value == 95 }
        func isDigit(_ value: UInt16) -> Bool { (48...57).contains(value) }
        while cursor < units.count, result.count < 3_000 {
            if cursor % 128 == 0, Task.isCancelled { return [] }
            let start = cursor
            let unit = units[cursor]
            var kind: SQLToken.Kind?
            if unit == 45, cursor + 1 < units.count, units[cursor + 1] == 45 {
                cursor += 2
                while cursor < units.count, units[cursor] != 10 { cursor += 1 }
                kind = .comment
            } else if unit == 47, cursor + 1 < units.count, units[cursor + 1] == 42 {
                cursor += 2
                var depth = 1
                while cursor + 1 < units.count, depth > 0 {
                    if units[cursor] == 47, units[cursor + 1] == 42 { depth += 1; cursor += 2 }
                    else if units[cursor] == 42, units[cursor + 1] == 47 { depth -= 1; cursor += 2 }
                    else { cursor += 1 }
                }
                if depth > 0 { cursor = units.count }
                kind = .comment
            } else if unit == 39 || unit == 34 {
                cursor += 1
                while cursor < units.count {
                    if units[cursor] == unit {
                        cursor += 1
                        if cursor < units.count, units[cursor] == unit { cursor += 1; continue }
                        break
                    }
                    cursor += 1
                }
                kind = unit == 39 ? .string : nil
            } else if isDigit(unit) {
                cursor += 1
                while cursor < units.count, isDigit(units[cursor]) || units[cursor] == 46 { cursor += 1 }
                kind = .number
            } else if isLetter(unit) {
                cursor += 1
                while cursor < units.count, isLetter(units[cursor]) || isDigit(units[cursor]) || units[cursor] == 36 { cursor += 1 }
                let word = String(decoding: units[start..<cursor], as: UTF16.self).uppercased()
                if keywords.contains(word) { kind = .keyword }
            } else { cursor += 1 }
            if let kind { result.append(SQLToken(range: NSRange(location: start, length: cursor - start), kind: kind)) }
        }
        return result
    }
}
