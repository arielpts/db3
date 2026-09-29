import AppKit
import DB3Core

/// One immutable vocabulary per editor. Only bounded result indices cross back
/// from the search worker; a newer source snapshot cannot rewrite this editor.
@MainActor
final class ResultChoiceModel {
    let choices: ValueChoiceSet
    let original: DatabaseValue
    private(set) var indices: [Int]
    private(set) var totalMatches: Int
    private(set) var selectedRow = -1
    private(set) var selection: DatabaseValue?
    private(set) var searching = false
    private(set) var error: String?
    var onChange: (() -> Void)?
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    init(choices: ValueChoiceSet, original: DatabaseValue) {
        self.choices = choices; self.original = original
        indices = Array(choices.choices.indices.prefix(200)); totalMatches = choices.choices.count
        if case .text(let key) = original, let position = indices.firstIndex(where: { choices.choices[$0].key.utf8.elementsEqual(key.utf8) }) { selectedRow = position }
    }
    var editedValue: DatabaseValue { selection ?? original }
    var isUnknown: Bool { if case .text(let key) = original { !choices.contains(key: key) } else { false } }
    var currentDescription: String {
        if original == .null { return "Current: SQL NULL" }
        let preview = String(original.displayText.prefix(512))
        return "Current: \(preview.isEmpty ? "\"\" (empty text)" : preview)\(isUnknown ? " · absent from known choices; preserved unchanged" : "")"
    }
    var resultDescription: String {
        if let error { return error }
        if searching { return "Searching all \(choices.choices.count) choices…" }
        if totalMatches > indices.count { return "Showing \(indices.count) of \(totalMatches) matches. Refine the search to see more." }
        return "\(totalMatches) \(totalMatches == 1 ? "choice" : "choices")"
    }
    func select(row: Int) {
        guard indices.indices.contains(row) else { return }
        selectedRow = row; selection = .text(choices.choices[indices[row]].key)
    }
    func moveSelection(by offset: Int) {
        guard !indices.isEmpty else { return }
        select(row: max(0, min(indices.count - 1, selectedRow + offset)))
        onChange?()
    }
    func search(_ query: String) {
        generation += 1; let expected = generation
        searchTask?.cancel(); searching = true; error = nil; onChange?()
        let choices = choices
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
                let worker = Task.detached(priority: .userInitiated) { try choices.search(query) }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.generation == expected else { return }
                self.indices = result.indices; self.totalMatches = result.totalMatches; self.selectedRow = -1
                // Filtering never changes the pending key or unknown original.
                if case .text(let key) = self.editedValue {
                    self.selectedRow = self.indices.firstIndex { choices.choices[$0].key.utf8.elementsEqual(key.utf8) } ?? -1
                }
                self.searching = false; self.searchTask = nil; self.onChange?()
            } catch {
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.searching = false; self.error = error.localizedDescription; self.onChange?()
            }
        }
    }
    func stop() { generation += 1; searchTask?.cancel(); searchTask = nil; onChange = nil }
}

@MainActor
final class ResultChoiceTable: NSTableView {
    var onStage: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { onStage?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
final class ResultChoiceEditor: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let definition: GridCellEdit
    let model: ResultChoiceModel
    let searchField = NSSearchField()
    let table = ResultChoiceTable()
    private let status = NSTextField(labelWithString: "")
    private let stageButton = NSButton()
    private var publishing = false
    var onStage: ((DatabaseValue) -> Void)?
    var onCancel: (() -> Void)?
    var onRawValue: (() -> Void)?
    var onChooseReference: (() -> Void)?
    var onSetNull: (() -> Void)?
    var onUseDefault: (() -> Void)?
    var usesSheet: Bool { model.choices.choices.count > 12 }

    init(_ definition: GridCellEdit, choices: ValueChoiceSet) {
        self.definition = definition; model = ResultChoiceModel(choices: choices, original: definition.value)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: usesSheet ? 620 : 460, height: usesSheet ? 480 : 380))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: definition.label); title.font = .systemFont(ofSize: 14, weight: .semibold)
        let currentDescription = definition.usesDefault ? "Current: database default" : model.currentDescription
        let current = NSTextField(wrappingLabelWithString: currentDescription)
        current.font = .systemFont(ofSize: 11); current.maximumNumberOfLines = 3
        current.setAccessibilityLabel(currentDescription)
        let source = NSTextField(wrappingLabelWithString: model.choices.statusText)
        source.font = .systemFont(ofSize: 11); source.textColor = .secondaryLabelColor; source.maximumNumberOfLines = 2
        searchField.placeholderString = "Search labels, keys, and descriptions"
        searchField.delegate = self; searchField.formatter = ResultScalarFormatter()
        searchField.setAccessibilityLabel("Search choices for \(definition.label)")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table.headerView = nil; table.rowHeight = 48; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("choice")))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(stageClickedRow)
        table.onStage = { [weak self] in self?.stage() }; table.onCancel = { [weak self] in self?.onCancel?() }
        table.setAccessibilityLabel("Values for \(definition.label)")
        scroll.documentView = table
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 8
        let valueActions = NSStackView(); valueActions.orientation = .horizontal; valueActions.spacing = 8
        buttons.addArrangedSubview(NSButton(title: "Cancel", target: self, action: #selector(cancel)))
        if definition.nullable { valueActions.addArrangedSubview(NSButton(title: "Set NULL", target: self, action: #selector(setNull))) }
        if definition.canUseDefault { valueActions.addArrangedSubview(NSButton(title: "Use Default", target: self, action: #selector(useDefault))) }
        if !model.choices.isAuthoritative { valueActions.addArrangedSubview(NSButton(title: "Edit Raw Value…", target: self, action: #selector(rawValue))) }
        if definition.canChooseReference { valueActions.addArrangedSubview(NSButton(title: "Referenced Row…", target: self, action: #selector(reference))) }
        stageButton.title = "Stage Value"; stageButton.target = self; stageButton.action = #selector(stage); stageButton.bezelStyle = .rounded
        buttons.addArrangedSubview(stageButton)
        [title, current, source, searchField, scroll, status].forEach(stack.addArrangedSubview)
        if !valueActions.arrangedSubviews.isEmpty { stack.addArrangedSubview(valueActions) }
        stack.addArrangedSubview(buttons)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80), current.widthAnchor.constraint(equalTo: stack.widthAnchor),
            source.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = container
        model.onChange = { [weak self] in self?.publish() }
        publish()
    }
    private func publish() {
        publishing = true
        status.stringValue = model.resultDescription
        stageButton.isEnabled = !model.searching
        table.reloadData()
        if model.selectedRow >= 0 {
            table.selectRowIndexes(IndexSet(integer: model.selectedRow), byExtendingSelection: false)
            table.scrollRowToVisible(model.selectedRow)
        } else { table.deselectAll(nil) }
        publishing = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.indices.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = model.choices.choices[model.indices[row]]
        let identifier = NSUserInterfaceItemIdentifier("choiceCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = identifier
        let text: NSTextField
        if let existing = cell.textField { text = existing }
        else {
            text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false
            text.maximumNumberOfLines = 2; text.lineBreakMode = .byTruncatingTail; cell.textField = text; cell.addSubview(text)
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        let key = item.key.isEmpty ? "\"\"" : String(item.key.prefix(256))
        let label = String(item.label.prefix(256))
        let primary = item.key == item.label ? label : "\(label) — \(key)"
        let description = String((item.description ?? item.shortLabel ?? "").prefix(512))
        text.stringValue = primary + (description.isEmpty ? "" : "\n" + description)
        let isCurrent = model.original == .text(item.key)
        let accessible = "\(label), stored key \(key)\(isCurrent ? ", current value" : "")\(description.isEmpty ? "" : ", " + description)"
        text.setAccessibilityLabel(accessible); cell.setAccessibilityLabel(accessible)
        cell.toolTip = [primary, description, item.icon.map { String($0.prefix(128)) }, item.color.map { String($0.prefix(128)) }, item.shortLabel.map { String($0.prefix(256)) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !publishing { model.select(row: table.selectedRow) } }
    func controlTextDidChange(_ obj: Notification) { model.search(searchField.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if selector == #selector(NSResponder.moveDown(_:)) { model.moveSelection(by: 1); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { model.moveSelection(by: -1); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { stage(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
    @objc private func stage() { if !model.searching { onStage?(model.editedValue) } }
    @objc private func stageClickedRow() { guard table.clickedRow >= 0 else { return }; model.select(row: table.clickedRow); stage() }
    @objc private func cancel() { onCancel?() }
    @objc private func setNull() { if let onSetNull { onSetNull() } else { onStage?(.null) } }
    @objc private func useDefault() { onUseDefault?() }
    @objc private func rawValue() { onRawValue?() }
    @objc private func reference() { onChooseReference?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    func stop() { model.stop(); onStage = nil; onCancel = nil; onRawValue = nil; onChooseReference = nil; onSetNull = nil; onUseDefault = nil }
}

@MainActor
final class ResultChoicePanel: NSPanel, NSWindowDelegate {
    var onCancel: (() -> Void)?
    func windowShouldClose(_ sender: NSWindow) -> Bool { onCancel?(); return false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
