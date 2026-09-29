import AppKit
import DB3Core
import Observation

/// Cell coordinates are positions in this result revision, never database row identities.
public struct GridCellPresentation: Sendable, Equatable {
    public var value: DatabaseValue?
    public var isChanged: Bool
    public var readOnlyReason: String?
    public var annotation: String?
    public init(value: DatabaseValue? = nil, isChanged: Bool = false, readOnlyReason: String? = nil, annotation: String? = nil) {
        self.value = value; self.isChanged = isChanged; self.readOnlyReason = readOnlyReason
        self.annotation = annotation
    }
}

public struct GridCellEdit: Sendable {
    public enum Kind: Sendable { case scalar, multiline, boolean }
    public var value: DatabaseValue
    public var kind: Kind
    public var nullable: Bool
    public var label: String
    public var canChooseReference: Bool
    public var choices: ValueChoiceSet?
    public var usesDefault: Bool
    public var canUseDefault: Bool
    var validatedTextBytes = 0
    public init(value: DatabaseValue, kind: Kind = .scalar, nullable: Bool = false, label: String, canChooseReference: Bool = false,
                choices: ValueChoiceSet? = nil, usesDefault: Bool = false, canUseDefault: Bool = false) {
        self.value = value; self.kind = kind; self.nullable = nullable; self.label = label
        self.canChooseReference = canChooseReference
        self.choices = choices
        self.usesDefault = usesDefault; self.canUseDefault = canUseDefault
    }
}

/// A retained worksheet can finish or explicitly discard its active native cell editor.
/// Finishing only stages a local draft; this controller never executes SQL.
@MainActor @Observable
public final class ResultsGridEditorController {
    public private(set) var hasActiveEditor = false
    @ObservationIgnored var finishAction: (@MainActor () async throws -> Void)?
    @ObservationIgnored var cancelAction: (@MainActor () -> Void)?
    public init() {}
    public func finish() async throws { try await finishAction?() }
    public func cancel() { cancelAction?() }
    func setActive(_ active: Bool) { hasActiveEditor = active }
}

@MainActor
public struct ResultsGridEditing {
    public var revision: Int
    public var isEnabled: Bool
    public var controller: ResultsGridEditorController
    public var presentation: @MainActor (Int, Int) -> GridCellPresentation?
    public var load: @MainActor (Int, Int) async throws -> GridCellEdit
    public var stage: @MainActor (Int, Int, DatabaseValue) async throws -> Void
    public var chooseReference: (@MainActor (Int, Int) -> Void)?
    public var reserveEditor: (@MainActor () throws -> AnyObject)?
    public var onActiveEditorChanged: (@MainActor (Bool) -> Void)?
    public var onError: @MainActor (String) -> Void
    public var undo: (@MainActor () -> Void)?
    public var redo: (@MainActor () -> Void)?
    /// Local insert drafts and the trailing blank row, beyond fetched rows.
    public var additionalRowCount: Int
    public var insertionRow: Int?
    /// Creates a local draft at insertionRow and returns its writable column.
    public var insert: (@MainActor (Int) async throws -> Int)?
    public var stageDefault: (@MainActor (Int, Int) async throws -> Void)?

    public init(
        revision: Int,
        isEnabled: Bool = true,
        controller: ResultsGridEditorController,
        presentation: @escaping @MainActor (Int, Int) -> GridCellPresentation? = { _, _ in nil },
        load: @escaping @MainActor (Int, Int) async throws -> GridCellEdit,
        stage: @escaping @MainActor (Int, Int, DatabaseValue) async throws -> Void,
        chooseReference: (@MainActor (Int, Int) -> Void)? = nil,
        reserveEditor: (@MainActor () throws -> AnyObject)? = nil,
        onActiveEditorChanged: (@MainActor (Bool) -> Void)? = nil,
        onError: @escaping @MainActor (String) -> Void,
        undo: (@MainActor () -> Void)? = nil,
        redo: (@MainActor () -> Void)? = nil,
        additionalRowCount: Int = 0,
        insertionRow: Int? = nil,
        insert: (@MainActor (Int) async throws -> Int)? = nil,
        stageDefault: (@MainActor (Int, Int) async throws -> Void)? = nil
    ) {
        self.revision = revision; self.isEnabled = isEnabled; self.controller = controller
        self.presentation = presentation; self.load = load; self.stage = stage
        self.chooseReference = chooseReference; self.onActiveEditorChanged = onActiveEditorChanged
        self.reserveEditor = reserveEditor
        self.onError = onError; self.undo = undo; self.redo = redo
        self.additionalRowCount = max(0, additionalRowCount); self.insertionRow = insertionRow
        self.insert = insert; self.stageDefault = stageDefault
    }
}

/// Background validation before an exact value crosses into a native text control.
/// NULL is kept separately, so an empty field always means empty text.
enum GridEditorValue {
    static let maximumBytes = 1_024 * 1_024
    static func validate(_ edit: GridCellEdit) throws -> GridCellEdit {
        let bytes = edit.value.byteCount
        guard bytes <= maximumBytes else {
            throw DatabaseError("This value is larger than the 1 MiB edit limit. It can still be inspected and copied.")
        }
        var result = edit
        result.validatedTextBytes = edit.value == .null ? 0 : bytes - 8
        if case .text(let text) = edit.value, edit.kind == .scalar,
           text.utf16.count > 1_024 || text.contains("\n") || text.contains("\r") {
            result.kind = .multiline
        }
        return result
    }
}

@MainActor
final class ResultEditingTable: NSTableView {
    var handleKey: ((NSEvent) -> Bool)?
    var makeCellMenu: ((Int, Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let targetRow = row(at: point)
        let targetColumn = column(at: point)
        if targetRow >= 0, targetColumn > 0 {
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            return makeCellMenu?(targetRow, targetColumn - 1) ?? super.menu(for: event)
        }
        return super.menu(for: event)
    }
}

@MainActor
final class ResultEditingField: NSTextField {
    private let cellUndo = UndoManager()
    override var undoManager: UndoManager? { cellUndo }
    func resetUndo() { cellUndo.removeAllActions() }
}

@MainActor
final class ResultEditingActionsButton: NSButton {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // This button overlays a result cell. Fill beneath the native bezel so
        // its translucent edges cannot reveal the cell's original value.
        NSColor.textBackgroundColor.withAlphaComponent(1).setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Short scalar inputs stay small. Larger source values use the multiline editor.
/// The backend still performs the authoritative type and exact-byte validation.
final class ResultScalarFormatter: Formatter {
    override func string(for obj: Any?) -> String? { obj as? String }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString; return true
    }
    override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        // Bounded scanning: rejects a huge paste without walking the whole input.
        partialString.utf8.prefix(4_097).count <= 4_096
    }
}

@MainActor
final class ResultEditingText: NSTextView {
    private let valueUndo = UndoManager()
    override var undoManager: UndoManager? { valueUndo }
    var cancelEdit: (() -> Void)?
    var stageEdit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelEdit?(); return }
        if event.keyCode == 36, event.modifierFlags.contains(.command) { stageEdit?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
final class ResultValuePopover: NSViewController, NSTextViewDelegate {
    let definition: GridCellEdit
    let text = ResultEditingText()
    let boolean = NSPopUpButton()
    var onStage: ((DatabaseValue) -> Void)?
    var onCancel: (() -> Void)?
    var onChooseReference: (() -> Void)?
    var onSetNull: (() -> Void)?
    var onUseDefault: (() -> Void)?
    private var originalValue: DatabaseValue
    private var textEdited = false
    var hasEditedValue: Bool { textEdited }
    private var textBytes: Int

    init(_ definition: GridCellEdit) {
        self.definition = definition; self.originalValue = definition.value
        textBytes = definition.validatedTextBytes
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: definition.kind == .boolean ? 130 : 290))
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: definition.label)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)
        if let choices = definition.choices, !choices.isResolved {
            let status = NSTextField(wrappingLabelWithString: choices.statusText)
            status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
            stack.addArrangedSubview(status)
        }
        if definition.kind == .boolean {
            boolean.addItems(withTitles: ["False", "True"])
            if case .text(let value) = definition.value { boolean.selectItem(at: ["t", "true", "1"].contains(value.lowercased()) ? 1 : 0) }
            if definition.value == .null {
                boolean.addItem(withTitle: definition.usesDefault ? "DEFAULT (unchanged)" : "NULL (unchanged)")
                boolean.lastItem?.isEnabled = false
                boolean.selectItem(at: 2)
            }
            boolean.target = self; boolean.action = #selector(booleanChanged)
            boolean.setAccessibilityLabel(definition.label)
            stack.addArrangedSubview(boolean)
        } else {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.allowsUndo = true; text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.string = if case .text(let value) = definition.value { value } else { "" }
            text.delegate = self
            text.setAccessibilityLabel(definition.label)
            text.cancelEdit = { [weak self] in self?.onCancel?() }
            text.stageEdit = { [weak self] in self?.stage() }
            scroll.documentView = text
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let hint = NSTextField(labelWithString: "⌘Return stages this value. Return inserts a line break.")
            hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
            stack.addArrangedSubview(hint)
        }
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        let valueActions = NSStackView(); valueActions.orientation = .horizontal; valueActions.spacing = 8
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        controls.addArrangedSubview(cancelButton)
        if definition.nullable { valueActions.addArrangedSubview(NSButton(title: "Set NULL", target: self, action: #selector(setNull))) }
        if definition.canUseDefault { valueActions.addArrangedSubview(NSButton(title: "Use Default", target: self, action: #selector(useDefault))) }
        if definition.canChooseReference { valueActions.addArrangedSubview(NSButton(title: "Choose referenced row…", target: self, action: #selector(chooseReference))) }
        let stageButton = NSButton(title: "Stage Value", target: self, action: #selector(stage))
        if definition.kind == .boolean { stageButton.keyEquivalent = "\r" }
        controls.addArrangedSubview(stageButton)
        if !valueActions.arrangedSubviews.isEmpty { stack.addArrangedSubview(valueActions) }
        stack.addArrangedSubview(controls)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        view = container
    }
    var editedValue: DatabaseValue {
        if definition.kind == .boolean {
            // Preserve the exact original (including PostgreSQL's t/f spelling)
            // until the user deliberately chooses a different boolean.
            if !textEdited { return originalValue }
            return .text(boolean.indexOfSelectedItem == 1 ? "true" : "false")
        }
        if !textEdited, originalValue == .null { return .null }
        return .text(text.string)
    }
    func textDidChange(_ notification: Notification) { textEdited = true }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let current = textView.string as NSString
        guard affectedCharRange.location != NSNotFound, NSMaxRange(affectedCharRange) <= current.length else { return false }
        // NSString's length is constant-time. Reject enormous pastes before
        // copying them into the editor, then check the bounded UTF-8 payload.
        guard (replacementString as NSString).length <= GridEditorValue.maximumBytes else { return false }
        let nextBytes = textBytes - current.substring(with: affectedCharRange).utf8.count + replacementString.utf8.count
        guard nextBytes + 8 <= GridEditorValue.maximumBytes else { return false }
        textBytes = nextBytes
        return true
    }
    @objc func booleanChanged() { textEdited = true }
    @objc private func stage() { onStage?(editedValue) }
    @objc private func cancel() { onCancel?() }
    @objc private func setNull() { if let onSetNull { onSetNull() } else { onStage?(.null) } }
    @objc private func useDefault() { onUseDefault?() }
    @objc private func chooseReference() { onChooseReference?() }
}
