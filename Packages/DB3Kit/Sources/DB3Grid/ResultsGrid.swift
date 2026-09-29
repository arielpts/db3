import AppKit
import CoreText
import QuartzCore
import DB3Core
import SwiftUI

/// A virtualized native table. The loader must return rows in the requested order.
/// Increment revision when replacing a result; changing rowCount appends rows to
/// the current result without discarding already displayed pages.
/// Retain this view's identity and set isActive to false while its tab or output
/// pane is hidden. Native presentation state survives; background reads pause.
@MainActor
public struct ResultsGrid: NSViewRepresentable {
    private let columns: [DatabaseColumn]
    private let rowCount: Int
    private let revision: Int
    private let isActive: Bool
    private let loadRows: @Sendable (Range<Int>) async throws -> [DatabaseRow]
    private let onSelect: (@MainActor (Int, DatabaseColumn, DatabaseValue) -> Void)?
    private let editing: ResultsGridEditing?
    private var totalRowCount: Int { rowCount + (editing?.additionalRowCount ?? 0) }

    public init(
        columns: [DatabaseColumn],
        rowCount: Int,
        revision: Int,
        isActive: Bool = true,
        loadRows: @escaping @Sendable (Range<Int>) async throws -> [DatabaseRow],
        onSelect: (@MainActor (Int, DatabaseColumn, DatabaseValue) -> Void)? = nil,
        editing: ResultsGridEditing? = nil
    ) {
        self.columns = columns
        self.rowCount = max(0, rowCount)
        self.revision = revision
        self.isActive = isActive
        self.loadRows = loadRows
        self.onSelect = onSelect
        self.editing = editing
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    // Also used by headless AppKit layout tests; no window or desktop is opened.
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let table = ResultEditingTable()
        let header = ResultHeaderView(frame: table.headerView?.frame ?? NSRect(x: 0, y: 0, width: 0, height: 24))
        header.tableView = table
        table.headerView = header
        table.style = .plain
        table.rowHeight = 27
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .textBackgroundColor
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = .separatorColor.withAlphaComponent(0.35)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .regular
        table.setAccessibilityLabel("Query results")
        table.setAccessibilityHelp("Select a cell to inspect its complete value. Double-click, Return, or F2 edits an eligible cell. Edits are staged locally.")
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.action = #selector(Coordinator.cellClicked(_:))
        table.doubleAction = #selector(Coordinator.cellDoubleClicked(_:))
        table.handleKey = { [weak coordinator] in coordinator?.handleKey($0) ?? false }
        table.makeCellMenu = { [weak coordinator] in coordinator?.cellMenu(row: $0, column: $1) }
        scroll.documentView = table
        coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    public func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    public static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
        (view.documentView as? NSTableView)?.delegate = nil
        (view.documentView as? NSTableView)?.dataSource = nil
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        private var parent: ResultsGrid
        private weak var table: NSTableView?
        private weak var clipView: NSClipView?
        private var cache: [TileKey: PreparedTile] = [:]
        private var recency: [TileKey] = []
        private var residentBytes = 0
        private var pending: [TileKey] = []
        private var failed: Set<TileKey> = []
        private var loadingKey: TileKey?
        private var loadTask: Task<PreparedTile, Error>?
        private var completionTask: Task<Void, Never>?
        private var selectionTask: Task<Void, Never>?
        private var headerTask: Task<[Double], Never>?
        private var headerCompletionTask: Task<Void, Never>?
        private var columnLayoutTask: Task<Void, Never>?
        private var headerWidths: [Double] = []
        private var headersMeasured = false
        private var contentWidths: [Double] = []
        private var sampledRowPages: [Int?] = []
        private var sampledRowCounts: [Int] = []
        private var manualWidths: [Int: Double] = [:]
        private var lastViewportWidth = 0.0
        private var columnLayoutDirty = true
        private var isApplyingColumnWidths = false
        private var valueFontName = ""
        private var selectedColumn = 0
        private var generation = 0
        private var isStopped = false
        private var needsResultReset = false
        private var displayedRowCount: Int
        private var displayedFetchedRowCount: Int
        private var insertionTask: Task<Void, Never>?
        private var insertionGeneration = 0
        private var editorTask: Task<Void, Never>?
        private var editorGeneration = 0
        private var editorRow: Int?
        private var editorColumn: Int?
        private var editorDefinition: GridCellEdit?
        private var editorLease: AnyObject?
        private var editorOriginal: DatabaseValue?
        private var editorChanged = false
        private var editorStaging = false
        private var field: ResultEditingField?
        private var fieldActions: NSButton?
        private var valuePopover: NSPopover?
        private var valueEditor: ResultValuePopover?
        var choiceEditor: ResultChoiceEditor?
        private var choicePanel: ResultChoicePanel?
        private static let byteLimit = 4 * 1_024 * 1_024
        private static let tileLimit = 12

        fileprivate init(parent: ResultsGrid) {
            self.parent = parent
            displayedRowCount = parent.totalRowCount
            displayedFetchedRowCount = parent.rowCount
        }

        fileprivate func attach(table: NSTableView, scroll: NSScrollView) {
            self.table = table
            bindEditorController()
            clipView = scroll.contentView
            valueFontName = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
            rebuildColumns()
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
            table.reloadData()
            scheduleColumnLayout()
            enqueueViewport()
        }

        func update(parent: ResultsGrid) {
            let reset = self.parent.revision != parent.revision || self.parent.columns != parent.columns || parent.rowCount < self.parent.rowCount
            let overlayChanged = self.parent.editing?.revision != parent.editing?.revision
            if self.parent.editing?.controller !== parent.editing?.controller {
                cancelEditor()
                self.parent.editing?.controller.finishAction = nil
                self.parent.editing?.controller.cancelAction = nil
            }
            let wasActive = self.parent.isActive
            self.parent = parent
            bindEditorController()
            needsResultReset = needsResultReset || reset
            if reset { cancelEditor() }
            if wasActive && !parent.isActive { cancelInsertion(); cancelWork(); valuePopover?.close(); hideChoicePanel() }
            // Keep native selection, widths, and scroll untouched while hidden.
            // A background query may replace/append its result; apply only its
            // latest presentation when the owning worksheet becomes visible.
            guard !isStopped, parent.isActive, let table else { return }
            let previousCount = displayedRowCount
            let previousFetchedCount = displayedFetchedRowCount
            displayedRowCount = parent.totalRowCount
            displayedFetchedRowCount = parent.rowCount
            if let row = editorRow, row >= displayedRowCount || row == parent.editing?.insertionRow { cancelEditor() }
            if needsResultReset {
                invalidate()
                rebuildColumns()
                table.deselectAll(nil)
                table.reloadData()
                needsResultReset = false
            } else if parent.totalRowCount != previousCount || parent.rowCount != previousFetchedCount {
                // A partially filled tail page must be refetched when more rows
                // arrive. Complete pages keep their stable row identities.
                if parent.rowCount != previousFetchedCount {
                    let tailPage = previousFetchedCount / TileKey.rowsPerTile
                    for key in Array(cache.keys) where key.rowPage >= tailPage { removeCached(key) }
                    failed.removeAll()
                }
                table.noteNumberOfRowsChanged()
                if String(previousCount).count != String(parent.totalRowCount).count { columnLayoutDirty = true }
            }
            measureHeaders()
            scheduleColumnLayout()
            enqueueViewport()
            if overlayChanged { reloadVisibleValues() }
            if !wasActive { restoreEditorPresentation() }
        }

        private func rebuildColumns() {
            guard let table else { return }
            isApplyingColumnWidths = true
            defer { isApplyingColumnWidths = false }
            let count = parent.columns.count
            headerWidths = parent.columns.map { min(320, max(64, Double($0.name.utf16.prefix(64).count) * 7 + 20)) }
            headersMeasured = false
            contentWidths = Array(repeating: 64, count: count)
            sampledRowPages = Array(repeating: nil, count: count)
            sampledRowCounts = Array(repeating: 0, count: count)
            manualWidths.removeAll()
            lastViewportWidth = 0
            columnLayoutDirty = true
            for column in table.tableColumns { table.removeTableColumn(column) }
            let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row-number"))
            number.headerCell = ResultHeaderCell(textCell: "#")
            number.headerCell.alignment = .right
            number.width = 60
            number.minWidth = 48
            number.maxWidth = 120
            number.resizingMask = []
            table.addTableColumn(number)
            for (position, metadata) in parent.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value-\(position)"))
                column.headerCell = ResultHeaderCell(textCell: metadata.name)
                column.headerCell.alignment = metadata.resultAlignment
                column.headerToolTip = "\(metadata.name) · PostgreSQL type OID \(metadata.typeOID)"
                column.width = headerWidths[position]
                column.minWidth = 64
                column.maxWidth = 1_200
                column.resizingMask = .userResizingMask
                table.addTableColumn(column)
            }
            invalidateHeaderCursorRects()
            measureHeaders()
        }

        private func measureHeaders() {
            guard !isStopped, parent.isActive, !headersMeasured, headerTask == nil, let table else { return }
            let names = parent.columns.map { String(decoding: $0.name.utf16.prefix(128), as: UTF16.self) }
            let font = table.tableColumns.first?.headerCell.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            let fontSize = font.pointSize
            let expectedGeneration = generation
            let work = Task.detached(priority: .userInitiated) {
                let measurer = TextWidthMeasurement(size: fontSize)
                return names.map { Task.isCancelled ? 64 : min(320, max(64, measurer.width(of: $0) + 24)) }
            }
            headerTask = work
            headerCompletionTask = Task { [weak self] in
                let widths = await work.value
                guard !Task.isCancelled, let self, !self.isStopped, self.parent.isActive, self.generation == expectedGeneration else { return }
                self.headerWidths = widths
                self.headersMeasured = true
                self.headerTask = nil
                self.headerCompletionTask = nil
                self.columnLayoutDirty = true
                self.scheduleColumnLayout()
            }
        }

        private func scheduleColumnLayout() {
            guard !isStopped, parent.isActive, !isApplyingColumnWidths, let clipView else { return }
            let width = Double(clipView.bounds.width)
            guard width > 0, columnLayoutDirty || abs(width - lastViewportWidth) >= 0.5,
                  columnLayoutTask == nil else { return }
            // Coalesce live-resize notifications and never change column widths
            // recursively inside an AppKit layout/scroll notification.
            let expectedGeneration = generation
            columnLayoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled, let self, !self.isStopped, self.parent.isActive, self.generation == expectedGeneration else { return }
                self.columnLayoutTask = nil
                self.applyColumnWidths()
            }
        }

        private func applyColumnWidths() {
            guard !isStopped, parent.isActive, let table, let clipView, table.tableColumns.count == parent.columns.count + 1 else { return }
            let viewport = Double(clipView.bounds.width)
            guard viewport.isFinite, viewport > 0 else { return }
            let numberWidth = min(120.0, max(48, Double(String(max(1, parent.totalRowCount)).count) * 8 + 20))
            let automatic = parent.columns.indices.filter { manualWidths[$0] == nil }
            // Native column rects include one spacing interval per column.
            let gaps = Double(table.intercellSpacing.width) * Double(table.tableColumns.count)
            let available = max(0, viewport - numberWidth - gaps - manualWidths.values.reduce(0, +))
            let widths = ColumnWidthLayout.widths(
                preferred: automatic.map { max(headerWidths[$0], contentWidths[$0]) },
                minimum: automatic.map { min(180, headerWidths[$0]) },
                available: available,
                maximum: max(1200, viewport)
            )
            var allWidths = [numberWidth] + parent.columns.indices.map { manualWidths[$0] ?? 64 }
            for (offset, position) in automatic.enumerated() { allWidths[position + 1] = widths[offset] }

            columnLayoutDirty = false
            lastViewportWidth = viewport
            isApplyingColumnWidths = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                for (index, column) in table.tableColumns.enumerated() {
                    let width = allWidths[index]
                    if index > 0 { column.maxWidth = max(1200, viewport, width) }
                    if abs(column.width - width) >= 0.1 { column.width = width }
                }
                // Commit cell/header geometry in this nonanimated transaction,
                // including when an enclosing SwiftUI layout is animated.
                table.layoutSubtreeIfNeeded()
                table.headerView?.layoutSubtreeIfNeeded()
            }
            isApplyingColumnWidths = false
            invalidateHeaderCursorRects()
            positionScalarEditor()
            // A width change can expose a different set of virtualized columns.
            enqueueViewport()
            scheduleColumnLayout()
        }

        public func tableViewColumnDidResize(_ notification: Notification) {
            guard !isApplyingColumnWidths, !isStopped, parent.isActive, let table,
                  let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let index = table.tableColumns.firstIndex(of: column), index > 0 else { return }
            manualWidths[index - 1] = column.width
            columnLayoutDirty = true
            invalidateHeaderCursorRects()
            scheduleColumnLayout()
        }

        private func invalidateHeaderCursorRects() {
            guard !isStopped, parent.isActive, let header = table?.headerView else { return }
            header.window?.invalidateCursorRects(for: header)
        }

        public func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 0 }
            let target = tableView.tableColumns[column]
            let position = column - 1
            guard !isStopped, parent.isActive, tableView === table, parent.columns.indices.contains(position) else { return target.width }

            // AppKit identifies the column to the left of the double-clicked
            // divider. Reuse its bounded background measurements; never scan
            // rows or read storage synchronously in the native event handler.
            let fitted = min(target.maxWidth, max(target.minWidth, min(480, max(headerWidths[position], contentWidths[position]))))
            // Treat fitting as an explicit user width, even if it happens to
            // match the current width and AppKit sends no resize notification.
            manualWidths[position] = fitted
            columnLayoutDirty = true
            // Apply through our zero-animation path before AppKit assigns the
            // returned width, so its native follow-up has no distance to animate.
            applyColumnWidths()
            return fitted
        }

        public func numberOfRows(in tableView: NSTableView) -> Int { displayedRowCount }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row >= 0, row < parent.totalRowCount else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("result-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCell ?? ResultCell(identifier: identifier)
            guard tableColumn.identifier.rawValue != "row-number" else {
                let isInsertionRow = row == parent.editing?.insertionRow
                cell.configure(text: isInsertionRow ? "+" : String(row + 1), kind: .rowNumber, alignment: .right,
                               tooltip: isInsertionRow ? "Double-click to insert a row" : nil)
                cell.setPresentation(changed: false, annotation: nil)
                if isInsertionRow { cell.setAccessibilityHelp("Double-click to insert a row") }
                return cell
            }
            guard let position = Int(tableColumn.identifier.rawValue.dropFirst(6)), position < parent.columns.count else { return cell }
            let alignment = parent.columns[position].resultAlignment
            let key = TileKey(row: row, column: position)
            let presentation = parent.editing?.presentation(row, position)
            if row == parent.editing?.insertionRow {
                cell.configure(text: "", kind: .placeholder, alignment: alignment, tooltip: "Double-click to insert a row")
            } else if let overlay = presentation?.value {
                let value = CellPreview(overlay)
                cell.configure(text: value.text, kind: value.isNull ? .null : .value, alignment: alignment, tooltip: presentation?.readOnlyReason)
            } else if row >= parent.rowCount {
                // Synthetic rows belong entirely to the local edit overlay.
                cell.configure(text: "", kind: .placeholder, alignment: alignment, tooltip: presentation?.readOnlyReason)
            } else if let tile = cache[key], let value = tile.value(row: row, column: position) {
                touch(key)
                cell.configure(text: value.text, kind: value.isNull ? .null : .value, alignment: alignment, tooltip: presentation?.readOnlyReason ?? (value.isTruncated ? "Preview shortened. Select this cell to inspect the full value." : nil))
            } else if failed.contains(key) {
                cell.configure(text: "Unable to load", kind: .failed, alignment: alignment, tooltip: "This result page could not be loaded.")
            } else {
                cell.configure(text: "…", kind: .placeholder, alignment: alignment, tooltip: nil)
                enqueue(key)
            }
            cell.setPresentation(changed: presentation?.isChanged == true, annotation: presentation?.annotation)
            if row == parent.editing?.insertionRow { cell.setAccessibilityHelp("Double-click to insert a row") }
            return cell
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            inspectSelection()
        }

        @objc fileprivate func cellClicked(_ table: NSTableView) {
            if table.clickedColumn > 0 { selectedColumn = table.clickedColumn - 1 }
            inspectSelection()
        }

        @objc fileprivate func cellDoubleClicked(_ table: NSTableView) {
            // Header divider auto-fit remains NSTableView's native action.
            guard table.clickedRow >= 0,
                  table.clickedColumn > 0 || (table.clickedColumn == 0 && table.clickedRow == parent.editing?.insertionRow) else { return }
            beginEditing(row: table.clickedRow, column: max(0, table.clickedColumn - 1))
        }

        private func bindEditorController() {
            parent.editing?.controller.finishAction = { [weak self] in try await self?.finishEditor() }
            parent.editing?.controller.cancelAction = { [weak self] in self?.cancelEditor() }
        }

        fileprivate func handleKey(_ event: NSEvent) -> Bool {
            guard let table, parent.isActive else { return false }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z", editorRow == nil {
                if event.modifierFlags.contains(.shift) { parent.editing?.redo?() } else { parent.editing?.undo?() }
                return parent.editing != nil
            }
            if event.keyCode == 53, editorRow != nil { cancelEditor(); return true }
            if [36, 76, 120].contains(event.keyCode), table.selectedRow >= 0 {
                beginEditing(row: table.selectedRow, column: selectedColumn); return parent.editing != nil
            }
            if [123, 124].contains(event.keyCode), !parent.columns.isEmpty {
                selectedColumn = min(parent.columns.count - 1, max(0, selectedColumn + (event.keyCode == 123 ? -1 : 1)))
                table.scrollColumnToVisible(selectedColumn + 1)
                inspectSelection()
                return true
            }
            return false
        }

        /// Testable without opening a window. Exact values always come from the
        /// owner's async loader, never the bounded presentation tile.
        func beginEditing(row: Int, column: Int) {
            guard !isStopped, parent.isActive, row >= 0, row < parent.totalRowCount,
                  parent.columns.indices.contains(column), let editing = parent.editing else { return }
            guard editing.isEnabled else { editing.onError("Editing is unavailable while this worksheet is busy or its snapshot needs refreshing."); return }
            if row == editing.insertionRow {
                beginInsertion(row: row, column: column, editing: editing)
                return
            }
            cancelInsertion()
            if let reason = editing.presentation(row, column)?.readOnlyReason { editing.onError(reason); return }
            if row == editorRow, column == editorColumn { restoreEditorPresentation(); return }
            if editorRow != nil {
                let expected = editorGeneration
                let expectedRevision = parent.revision
                Task { [weak self] in
                    guard let self, self.editorGeneration == expected else { return }
                    do {
                        try await self.finishEditor()
                        guard self.parent.revision == expectedRevision, self.parent.editing?.controller === editing.controller else { return }
                        self.beginEditing(row: row, column: column)
                    }
                    catch { editing.onError(error.localizedDescription) }
                }
                return
            }
            startCellEditor(row: row, column: column, editing: editing)
        }

        private func beginInsertion(row: Int, column: Int, editing: ResultsGridEditing) {
            guard insertionTask == nil, let insert = editing.insert else { return }
            insertionGeneration &+= 1
            let expected = insertionGeneration
            insertionTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.insertionGeneration == expected { self.insertionTask = nil } }
                do {
                    try await self.finishEditor()
                    guard !Task.isCancelled, !self.isStopped, self.parent.isActive,
                          self.insertionGeneration == expected, self.parent.editing?.insertionRow == row,
                          self.parent.editing?.controller === editing.controller, self.parent.editing?.isEnabled == true else { return }
                    let targetColumn = try await insert(column)
                    guard !Task.isCancelled, !self.isStopped, self.parent.isActive,
                          self.insertionGeneration == expected, self.parent.editing?.controller === editing.controller else { return }
                    self.insertionTask = nil
                    guard self.parent.columns.indices.contains(targetColumn) else { return }
                    // The owner has created the draft synchronously, but its
                    // SwiftUI update may still be queued. Do not reinvoke insert.
                    self.startCellEditor(row: row, column: targetColumn, editing: editing)
                } catch {
                    guard !Task.isCancelled, self.insertionGeneration == expected else { return }
                    self.insertionTask = nil
                    editing.onError(error.localizedDescription)
                }
            }
        }

        private func cancelInsertion() {
            insertionGeneration &+= 1
            insertionTask?.cancel(); insertionTask = nil
        }

        private func startCellEditor(row: Int, column: Int, editing: ResultsGridEditing) {
            editorGeneration &+= 1
            let expected = editorGeneration
            editorRow = row; editorColumn = column
            selectedColumn = column
            editing.controller.setActive(true)
            editing.onActiveEditorChanged?(true)
            editorTask = Task { [weak self] in
                do {
                    let loaded = try await editing.load(row, column)
                    let validated = try await Task.detached(priority: .userInitiated) { try GridEditorValue.validate(loaded) }.value
                    guard !Task.isCancelled, let self, !self.isStopped, self.editorGeneration == expected else { return }
                    self.editorLease = try editing.reserveEditor?()
                    self.editorTask = nil
                    self.editorDefinition = validated
                    self.editorOriginal = validated.value
                    self.editorChanged = false
                    self.installEditor(validated)
                } catch {
                    guard !Task.isCancelled, let self, self.editorGeneration == expected else { return }
                    self.cancelEditor(); editing.onError(error.localizedDescription)
                }
            }
        }

        private func installEditor(_ definition: GridCellEdit) {
            guard let table else { return }
            if let choices = definition.choices, choices.isResolved {
                let contents = ResultChoiceEditor(definition, choices: choices)
                contents.onStage = { [weak self, weak contents] value in
                    self?.stageFromEvent(definition.usesDefault && contents?.model.selection == nil ? nil : value)
                }
                contents.onCancel = { [weak self] in self?.cancelEditor() }
                contents.onRawValue = { [weak self] in self?.openRawChoiceEditor() }
                contents.onChooseReference = { [weak self] in self?.chooseReference() }
                contents.onSetNull = { [weak self] in self?.stageFromEvent(.null) }
                contents.onUseDefault = { [weak self] in self?.useEditorDefault() }
                choiceEditor = contents
                if !contents.usesSheet {
                    let popover = NSPopover(); popover.behavior = .applicationDefined
                    popover.contentViewController = contents; valuePopover = popover
                }
                _ = contents.view
            } else if definition.kind == .scalar {
                let input = field ?? ResultEditingField()
                field = input
                input.delegate = self; input.isBordered = true; input.isBezeled = false
                input.formatter = ResultScalarFormatter()
                input.backgroundColor = .textBackgroundColor; input.drawsBackground = true
                input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                input.maximumNumberOfLines = 1
                input.cell?.usesSingleLineMode = true
                input.cell?.wraps = false
                input.cell?.isScrollable = true
                input.focusRingType = .exterior
                input.stringValue = if case .text(let value) = definition.value { value } else { "" }
                input.placeholderString = definition.usesDefault ? "DEFAULT" : (definition.value == .null ? "NULL" : nil)
                input.setAccessibilityLabel("Edit \(definition.label)")
                input.setAccessibilityHelp("Return or Tab stages this value. Escape cancels. An empty value is empty text; Set NULL is a separate action in the cell menu.")
                input.toolTip = definition.choices?.statusText
                input.resetUndo()
                table.addSubview(input)
                do {
                    let actions = fieldActions ?? ResultEditingActionsButton(title: "⋯", target: self, action: #selector(showEditorActions))
                    fieldActions = actions; actions.bezelStyle = .smallSquare
                    actions.setAccessibilityLabel("Value actions for \(definition.label)")
                    table.addSubview(actions)
                }
            } else {
                let contents = ResultValuePopover(definition)
                contents.onStage = { [weak self, weak contents] value in
                    self?.stageFromEvent(definition.usesDefault && contents?.hasEditedValue == false ? nil : value)
                }
                contents.onCancel = { [weak self] in self?.cancelEditor() }
                contents.onChooseReference = { [weak self] in self?.chooseReference() }
                contents.onSetNull = { [weak self] in self?.stageFromEvent(.null) }
                contents.onUseDefault = { [weak self] in self?.useEditorDefault() }
                valueEditor = contents
                let popover = NSPopover(); popover.behavior = .applicationDefined
                popover.contentViewController = contents
                valuePopover = popover
                _ = contents.view
            }
            restoreEditorPresentation()
        }

        private func restoreEditorPresentation() {
            guard parent.isActive, let table, let row = editorRow, let column = editorColumn,
                  editorDefinition != nil else { return }
            let rect = table.frameOfCell(atColumn: column + 1, row: row)
            positionScalarEditor()
            if let field, field.superview != nil {
                if let window = table.window { window.makeFirstResponder(field); field.selectText(nil) }
            } else if let choiceEditor, choiceEditor.usesSheet, let window = table.window {
                let panel: ResultChoicePanel
                if let existing = choicePanel { panel = existing }
                else {
                    panel = ResultChoicePanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
                    panel.title = choiceEditor.definition.label; panel.contentViewController = choiceEditor
                    panel.contentMinSize = NSSize(width: 480, height: 360)
                    panel.delegate = panel; panel.onCancel = { [weak self] in self?.cancelEditor() }
                    choicePanel = panel
                }
                if panel.sheetParent == nil { window.beginSheet(panel) }
                panel.makeFirstResponder(choiceEditor.searchField)
            } else if let popover = valuePopover, !popover.isShown, table.window != nil {
                popover.show(relativeTo: rect, of: table, preferredEdge: .maxY)
                if let choiceEditor { popover.contentViewController?.view.window?.makeFirstResponder(choiceEditor.searchField) }
                if let editor = valueEditor, editor.definition.kind != .boolean { popover.contentViewController?.view.window?.makeFirstResponder(editor.text) }
            }
        }

        private func positionScalarEditor() {
            guard let table, let row = editorRow, let column = editorColumn, let field, field.superview != nil else { return }
            let rect = table.frameOfCell(atColumn: column + 1, row: row).insetBy(dx: 2, dy: 2)
            let hasActions = fieldActions?.superview != nil
            // Use the native single-line height instead of stretching a text
            // field, whose baseline otherwise stays at the top of a tall row.
            let measuredHeight = field.intrinsicContentSize.height
            let height = min(rect.height, measuredHeight.isFinite && measuredHeight > 0 ? measuredHeight : rect.height)
            field.frame = NSRect(x: rect.minX, y: rect.midY - height / 2, width: max(12, rect.width - (hasActions ? 22 : 0)), height: height)
            if hasActions { fieldActions?.frame = NSRect(x: rect.maxX - 22, y: rect.minY, width: 22, height: rect.height) }
        }

        @objc private func showEditorActions() {
            guard let row = editorRow, let column = editorColumn, let actions = fieldActions,
                  let menu = cellMenu(row: row, column: column) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actions.bounds.maxY), in: actions)
        }

        public func controlTextDidChange(_ notification: Notification) { editorChanged = true }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Let the input method finish/cancel its marked composition before
            // treating Return, Tab, or Escape as an editor command.
            if textView.hasMarkedText() { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelEditor(); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                let direction = commandSelector == #selector(NSResponder.insertBacktab(_:)) ? -1 : (commandSelector == #selector(NSResponder.insertTab(_:)) ? 1 : 0)
                stageFromEvent(nil, move: direction); return true
            }
            return false
        }

        private func currentEditorValue() -> DatabaseValue? {
            if let choiceEditor { return choiceEditor.model.editedValue }
            if let valueEditor { return valueEditor.editedValue }
            if let field, field.superview != nil {
                return !editorChanged && editorOriginal == .null ? .null : .text(field.stringValue)
            }
            return nil
        }

        private func stageFromEvent(_ value: DatabaseValue?, move: Int = 0) {
            guard let editing = parent.editing else { return }
            let row = editorRow; let column = editorColumn
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.finishEditor(replacement: value)
                    if move != 0, let row, let column {
                        let nextColumn = column + move
                        if self.parent.columns.indices.contains(nextColumn) { self.selectedColumn = nextColumn; self.beginEditing(row: row, column: nextColumn) }
                    }
                } catch { editing.onError(error.localizedDescription) }
            }
        }

        func finishEditor(replacement: DatabaseValue? = nil) async throws {
            if let editorTask { await editorTask.value }
            guard let row = editorRow, let column = editorColumn, let definition = editorDefinition,
                  let editing = parent.editing, let value = replacement ?? currentEditorValue() else { return }
            guard !editorStaging else { throw DatabaseError("The current value is still being validated.") }
            guard editing.isEnabled else { throw DatabaseError("Finish the worksheet operation before staging this value.") }
            let isExplicitDefaultReplacement = definition.usesDefault && replacement != nil
            if value == .null, !definition.nullable, value != editorOriginal || isExplicitDefaultReplacement { throw DatabaseError("This column does not allow NULL.") }
            let expected = editorGeneration
            editorStaging = true
            defer { editorStaging = false }
            _ = try await Task.detached(priority: .userInitiated) { try GridEditorValue.validate(GridCellEdit(value: value, label: definition.label)) }.value
            guard editorGeneration == expected, !isStopped else { throw CancellationError() }
            if value != editorOriginal || isExplicitDefaultReplacement { try await editing.stage(row, column, value) }
            guard editorGeneration == expected, !isStopped else { return }
            cancelEditor(keepingInsertion: true)
            reloadVisibleValues()
        }

        func cancelEditor() {
            cancelEditor(keepingInsertion: false)
        }

        private func cancelEditor(keepingInsertion: Bool) {
            if !keepingInsertion { cancelInsertion() }
            editorGeneration &+= 1
            editorTask?.cancel(); editorTask = nil
            let wasEditing = editorRow != nil
            editorRow = nil; editorColumn = nil; editorDefinition = nil; editorOriginal = nil
            editorChanged = false
            field?.removeFromSuperview(); field?.stringValue = ""; field?.resetUndo()
            fieldActions?.removeFromSuperview()
            valuePopover?.close(); valuePopover = nil; valueEditor = nil
            hideChoicePanel(); choicePanel?.onCancel = nil; choicePanel = nil
            choiceEditor?.stop(); choiceEditor = nil
            editorLease = nil
            parent.editing?.controller.setActive(false)
            if wasEditing { parent.editing?.onActiveEditorChanged?(false) }
        }

        fileprivate func cellMenu(row: Int, column: Int) -> NSMenu? {
            guard let editing = parent.editing else { return nil }
            selectedColumn = column
            let menu = NSMenu()
            let isInsertionRow = row == editing.insertionRow
            let reason = isInsertionRow ? nil : editing.presentation(row, column)?.readOnlyReason
            let edit = NSMenuItem(title: reason.map { "Read only: \($0)" } ?? (isInsertionRow ? "Insert Row" : "Edit Value"), action: #selector(editSelectedCell), keyEquivalent: "")
            edit.target = self; edit.isEnabled = reason == nil && editing.isEnabled
            menu.addItem(edit); menu.autoenablesItems = false
            if row >= parent.rowCount, !isInsertionRow, reason == nil, editing.stageDefault != nil {
                let useDefault = NSMenuItem(title: "Use Default", action: #selector(useSelectedDefault(_:)), keyEquivalent: "")
                useDefault.target = self; useDefault.isEnabled = editing.isEnabled
                useDefault.representedObject = [row, column]
                menu.addItem(useDefault)
            }
            if editorRow == row, editorColumn == column, let definition = editorDefinition {
                if definition.kind == .scalar, choiceEditor == nil {
                    let expand = NSMenuItem(title: "Open Multiline Editor…", action: #selector(expandEditor), keyEquivalent: "")
                    expand.target = self; expand.isEnabled = editing.isEnabled; menu.addItem(expand)
                }
                if definition.nullable {
                    let null = NSMenuItem(title: "Set NULL", action: #selector(setSelectedNull), keyEquivalent: "")
                    null.target = self; null.isEnabled = editing.isEnabled; menu.addItem(null)
                }
                if definition.canChooseReference {
                    let foreignKey = NSMenuItem(title: "Choose referenced row…", action: #selector(chooseReference), keyEquivalent: "")
                    foreignKey.target = self; foreignKey.isEnabled = editing.isEnabled; menu.addItem(foreignKey)
                }
            }
            return menu
        }

        @objc private func editSelectedCell() { if let table { beginEditing(row: table.selectedRow, column: selectedColumn) } }
        @objc private func expandEditor() {
            guard var definition = editorDefinition, let value = currentEditorValue() else { return }
            definition.value = value; definition.kind = .multiline
            definition.validatedTextBytes = value == .null ? 0 : max(0, value.byteCount - 8)
            field?.removeFromSuperview(); fieldActions?.removeFromSuperview()
            editorDefinition = definition
            installEditor(definition)
        }
        @objc private func setSelectedNull() { stageFromEvent(.null) }
        private func useEditorDefault() {
            guard editorDefinition?.canUseDefault == true, let row = editorRow, let column = editorColumn else { return }
            useDefault(row: row, column: column)
        }
        @objc private func useSelectedDefault(_ sender: NSMenuItem) {
            guard let coordinate = sender.representedObject as? [Int], coordinate.count == 2 else { return }
            useDefault(row: coordinate[0], column: coordinate[1])
        }
        private func useDefault(row: Int, column: Int) {
            guard let editing = parent.editing, editing.isEnabled, let stageDefault = editing.stageDefault else { return }
            let expected = editorGeneration
            Task { [weak self] in
                guard let self, !self.isStopped, self.parent.isActive, self.editorGeneration == expected else { return }
                do {
                    if self.editorRow != nil, self.editorRow != row || self.editorColumn != column {
                        try await self.finishEditor()
                    }
                    let currentGeneration = self.editorGeneration
                    try await stageDefault(row, column)
                    guard !self.isStopped, self.editorGeneration == currentGeneration else { return }
                    self.cancelEditor()
                    self.reloadVisibleValues()
                } catch { editing.onError(error.localizedDescription) }
            }
        }
        private func hideChoicePanel() {
            guard let choicePanel else { return }
            choicePanel.sheetParent?.endSheet(choicePanel)
            choicePanel.orderOut(nil)
        }
        private func openRawChoiceEditor() {
            guard var definition = editorDefinition, let choices = definition.choices, !choices.isAuthoritative,
                  let value = currentEditorValue() else { return }
            definition.value = value; definition.choices = nil
            valuePopover?.close(); valuePopover = nil
            hideChoicePanel(); choicePanel?.onCancel = nil; choicePanel = nil
            choiceEditor?.stop(); choiceEditor = nil
            editorDefinition = definition
            installEditor(definition)
        }
        @objc private func chooseReference() {
            guard let row = editorRow, let column = editorColumn, let editing = parent.editing,
                  editing.isEnabled, editorDefinition?.canChooseReference == true else { return }
            cancelEditor()
            editing.chooseReference?(row, column)
        }

        private func reloadVisibleValues() {
            guard let table else { return }
            let rows = table.rows(in: table.visibleRect)
            guard rows.location != NSNotFound, rows.length > 0, !parent.columns.isEmpty else { return }
            let end = min(parent.totalRowCount, NSMaxRange(rows))
            if rows.location < end { table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<end), columnIndexes: IndexSet(integersIn: 0..<(parent.columns.count + 1))) }
        }

        private func inspectSelection() {
            selectionTask?.cancel()
            selectionTask = nil
            guard !isStopped, parent.isActive, let table, table.selectedRow >= 0,
                  parent.columns.indices.contains(selectedColumn), let callback = parent.onSelect else { return }
            let row = table.selectedRow
            guard row < parent.rowCount else { return }
            let position = selectedColumn
            let column = parent.columns[position]
            if let value = parent.editing?.presentation(row, position)?.value { callback(row, column, value); return }
            let loader = parent.loadRows
            let expectedGeneration = generation
            // Full values are loaded only when explicitly selected; tiles retain
            // bounded previews rather than duplicate entire large fields.
            selectionTask = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    let rows = try await loader(row..<(row + 1))
                    guard !Task.isCancelled, let self, !self.isStopped, self.parent.isActive, self.generation == expectedGeneration,
                          let result = rows.first, result.indices.contains(position) else { return }
                    callback(row, column, result[position])
                } catch { /* The grid continues to show the cached preview. */ }
            }
        }

        @objc private func viewportChanged(_ notification: Notification) {
            guard !isApplyingColumnWidths else { return }
            invalidateHeaderCursorRects()
            scheduleColumnLayout()
            enqueueViewport()
        }

        private func enqueueViewport() {
            guard !isStopped, parent.isActive, let table, parent.rowCount > 0 else { return }
            let rows = table.rows(in: table.visibleRect)
            guard rows.location != NSNotFound else { return }
            let lower = max(0, rows.location)
            let upper = min(parent.rowCount, max(lower + 1, NSMaxRange(rows)))
            guard lower < upper else { pending.removeAll(); return }
            let visibleColumns = table.columnIndexes(in: table.visibleRect).filter { $0 > 0 }.map { $0 - 1 }
            let columnPages = Set(visibleColumns.map { $0 / TileKey.columnsPerTile }).sorted()
            let rowPages = (lower / TileKey.rowsPerTile)...((max(lower, upper - 1)) / TileKey.rowsPerTile)
            var wanted: [TileKey] = []
            for rowPage in rowPages {
                for columnPage in columnPages {
                    if wanted.count < 16 { wanted.append(TileKey(rowPage: rowPage, columnPage: columnPage)) }
                }
            }
            // Scrolling replaces stale pending work rather than accumulating a
            // queue for every region through which the user moved.
            pending = pending.filter { wanted.contains($0) }
            for key in wanted { enqueue(key) }
        }

        private func enqueue(_ key: TileKey) {
            guard !isStopped, parent.isActive, cache[key] == nil, !failed.contains(key), loadingKey != key,
                  key.rowStart < parent.rowCount, !pending.contains(key), pending.count < 16 else { return }
            pending.append(key)
            startNextLoad()
        }

        private func startNextLoad() {
            guard !isStopped, parent.isActive, loadingKey == nil, !pending.isEmpty else { return }
            let key = pending.removeFirst()
            let end = min(parent.rowCount, key.rowStart + TileKey.rowsPerTile)
            guard key.rowStart < end else { startNextLoad(); return }
            loadingKey = key
            let loader = parent.loadRows
            let expectedGeneration = generation
            let columnCount = parent.columns.count
            let requests = (key.columnStart..<min(columnCount, key.columnStart + TileKey.columnsPerTile)).compactMap { position -> ColumnWidthRequest? in
                guard sampledRowCounts[position] < TileKey.rowsPerTile,
                      sampledRowPages[position] == nil || sampledRowPages[position] == key.rowPage else { return nil }
                return ColumnWidthRequest(column: position, skipRows: sampledRowCounts[position])
            }
            let fontName = valueFontName
            let work = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let rows = try await loader(key.rowStart..<end)
                try Task.checkCancellation()
                return PreparedTile(key: key, rows: rows, columnCount: columnCount, widthRequests: requests, fontName: fontName)
            }
            loadTask = work
            completionTask = Task { [weak self] in
                do {
                    let tile = try await work.value
                    guard !Task.isCancelled, let self, !self.isStopped, self.parent.isActive, self.generation == expectedGeneration else { return }
                    if end < self.parent.rowCount, end < key.rowStart + TileKey.rowsPerTile {
                        // Appends may race an in-flight tail-page read. Fetch its
                        // new range instead of caching an already stale tail.
                        self.pending.insert(key, at: 0)
                    } else {
                        self.mergeColumnMeasurements(tile)
                        self.insert(tile)
                        self.reload(tile: key, count: tile.rows.count)
                    }
                } catch {
                    guard !Task.isCancelled, let self, !self.isStopped, self.parent.isActive, self.generation == expectedGeneration else { return }
                    if self.failed.count >= 16 { self.failed.removeAll() }
                    self.failed.insert(key)
                    self.reload(tile: key, count: end - key.rowStart)
                }
                guard !Task.isCancelled, let self, !self.isStopped, self.parent.isActive, self.generation == expectedGeneration else { return }
                self.loadingKey = nil
                self.loadTask = nil
                self.completionTask = nil
                self.startNextLoad()
            }
        }

        private func insert(_ tile: PreparedTile) {
            removeCached(tile.key)
            while residentBytes + tile.byteCount > Self.byteLimit || cache.count >= Self.tileLimit {
                guard let oldest = recency.first else { break }
                removeCached(oldest)
            }
            cache[tile.key] = tile
            residentBytes += tile.byteCount
            recency.append(tile.key)
        }

        private func mergeColumnMeasurements(_ tile: PreparedTile) {
            var changed = false
            for sample in tile.widthSamples {
                sampledRowPages[sample.column] = tile.key.rowPage
                sampledRowCounts[sample.column] = sample.rowCount
                let width = min(480, max(64, sample.width + 20))
                if width > contentWidths[sample.column] {
                    contentWidths[sample.column] = width
                    changed = true
                }
            }
            if changed {
                columnLayoutDirty = true
                scheduleColumnLayout()
            }
        }

        private func touch(_ key: TileKey) {
            if recency.last != key { recency.removeAll { $0 == key }; recency.append(key) }
        }

        private func removeCached(_ key: TileKey) {
            if let old = cache.removeValue(forKey: key) { residentBytes -= old.byteCount }
            recency.removeAll { $0 == key }
        }

        private func reload(tile: TileKey, count: Int) {
            guard let table else { return }
            let end = min(parent.rowCount, tile.rowStart + count)
            let columnEnd = min(parent.columns.count, tile.columnStart + TileKey.columnsPerTile)
            guard tile.rowStart < end, tile.columnStart < columnEnd else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: tile.rowStart..<end), columnIndexes: IndexSet(integersIn: (tile.columnStart + 1)..<(columnEnd + 1)))
        }

        private func invalidate() {
            cancelWork()
            cache.removeAll()
            recency.removeAll()
            failed.removeAll()
            residentBytes = 0
        }

        // Increment the fence before cancelling: loaders may ignore cancellation
        // and return after a later activation has started work for the same tile.
        private func cancelWork() {
            generation &+= 1
            loadTask?.cancel()
            completionTask?.cancel()
            selectionTask?.cancel()
            headerTask?.cancel()
            headerCompletionTask?.cancel()
            columnLayoutTask?.cancel()
            loadTask = nil
            completionTask = nil
            selectionTask = nil
            headerTask = nil
            headerCompletionTask = nil
            columnLayoutTask = nil
            loadingKey = nil
            pending.removeAll()
        }

        fileprivate func stop() {
            isStopped = true
            cancelEditor()
            parent.editing?.controller.finishAction = nil
            parent.editing?.controller.cancelAction = nil
            invalidate()
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private struct TileKey: Hashable, Sendable {
    static let rowsPerTile = 64
    static let columnsPerTile = 8
    let rowPage: Int
    let columnPage: Int
    var rowStart: Int { rowPage * Self.rowsPerTile }
    var columnStart: Int { columnPage * Self.columnsPerTile }
    init(row: Int, column: Int) { rowPage = row / Self.rowsPerTile; columnPage = column / Self.columnsPerTile }
    init(rowPage: Int, columnPage: Int) { self.rowPage = rowPage; self.columnPage = columnPage }
}

private struct CellPreview: Sendable {
    let text: String
    let isNull: Bool
    let isTruncated: Bool
    var byteCount: Int { text.utf8.count + 64 }
    init(_ value: DatabaseValue) {
        switch value {
        case .null:
            text = "NULL"; isNull = true; isTruncated = false
        case .text(let value):
            // UTF-16 bounding avoids scanning a giant grapheme cluster. It also
            // keeps pathological fields from expanding the presentation cache.
            let prefix = Array(value.utf16.prefix(241))
            isTruncated = prefix.count > 240
            let visible = String(decoding: prefix.prefix(240), as: UTF16.self)
                .replacingOccurrences(of: "\n", with: " ↵ ")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\t", with: " ⇥ ")
            text = visible + (isTruncated ? "…" : "")
            isNull = false
        }
    }
}

private struct PreparedTile: Sendable {
    let key: TileKey
    let rows: [[CellPreview]]
    let byteCount: Int
    let widthSamples: [ColumnWidthSample]
    init(key: TileKey, rows: [DatabaseRow], columnCount: Int, widthRequests: [ColumnWidthRequest], fontName: String) {
        self.key = key
        let lastColumn = min(columnCount, key.columnStart + TileKey.columnsPerTile)
        self.rows = rows.prefix(TileKey.rowsPerTile).map { row in
            guard key.columnStart < min(lastColumn, row.count) else { return [] }
            return row[key.columnStart..<min(lastColumn, row.count)].map(CellPreview.init)
        }
        byteCount = self.rows.reduce(64) { $0 + $1.reduce(24) { $0 + $1.byteCount } }
        if widthRequests.isEmpty {
            widthSamples = []
        } else {
            let measurer = TextWidthMeasurement(fontName: fontName, size: 12)
            let preparedRows = self.rows
            widthSamples = widthRequests.compactMap { request in
                guard request.skipRows < preparedRows.count, !Task.isCancelled else { return nil }
                let offset = request.column - key.columnStart
                let width = preparedRows.dropFirst(request.skipRows).reduce(0.0) { widest, row in
                    guard row.indices.contains(offset) else { return widest }
                    return max(widest, measurer.width(of: row[offset].text))
                }
                return ColumnWidthSample(column: request.column, rowCount: preparedRows.count, width: width)
            }
        }
    }
    func value(row: Int, column: Int) -> CellPreview? {
        let rowOffset = row - key.rowStart
        let columnOffset = column - key.columnStart
        guard rows.indices.contains(rowOffset), rows[rowOffset].indices.contains(columnOffset) else { return nil }
        return rows[rowOffset][columnOffset]
    }
}

private struct ColumnWidthRequest: Sendable {
    let column: Int
    let skipRows: Int
}

private struct ColumnWidthSample: Sendable {
    let column: Int
    let rowCount: Int
    let width: Double
}

/// Created and used entirely inside a detached header/tile preparation job.
/// Core Text measures Unicode/fallback glyphs without touching AppKit views.
private struct TextWidthMeasurement {
    let font: CTFont
    init(fontName: String? = nil, size: CGFloat) {
        if let fontName {
            font = CTFontCreateWithName(fontName as CFString, size, nil)
        } else {
            // Private system font names cannot be reconstructed by name.
            font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
    }
    func width(of text: String) -> Double {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return width.isFinite ? ceil(max(0, width)) : 0
    }
}

private extension DatabaseColumn {
    var resultAlignment: NSTextAlignment {
        // PostgreSQL scalar numeric types: int8, int2, int4, oid, float4,
        // float8, money, numeric. Use metadata so numeric-looking text stays text.
        switch typeOID {
        case 20, 21, 23, 26, 700, 701, 790, 1700: .right
        default: .left
        }
    }
}

@MainActor
private final class ResultHeaderView: NSTableHeaderView {
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tableView, tableView.allowsColumnResizing else { return }
        let visible = visibleRect
        guard !visible.isEmpty else { return }
        // Keep the native drag and double-click handlers. Only supply the hover
        // affordance, including the right edge of the last visible data column.
        for index in tableView.columnIndexes(in: visible.insetBy(dx: -3, dy: 0)) {
            let column = tableView.tableColumns[index]
            guard !column.isHidden, column.resizingMask.contains(.userResizingMask), column.maxWidth > column.minWidth else { continue }
            let header = headerRect(ofColumn: index)
            let separator = NSRect(x: header.maxX - 3, y: header.minY, width: 6, height: header.height).intersection(visible)
            if !separator.isEmpty { addCursorRect(separator, cursor: .columnResize) }
        }
    }
}

@MainActor
private final class ResultHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Add space around the native title without moving its border or divider.
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 8, dy: 0), in: controlView)
    }
}

@MainActor
private final class ResultCell: NSTableCellView {
    enum Kind { case value, null, placeholder, rowNumber, failed }
    private let changeMarker = NSTextField(labelWithString: "•")
    private var labelLeading: NSLayoutConstraint?
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        changeMarker.font = .systemFont(ofSize: 10, weight: .bold)
        changeMarker.textColor = .systemOrange
        changeMarker.translatesAutoresizingMaskIntoConstraints = false
        changeMarker.isHidden = true
        changeMarker.setAccessibilityLabel("Local draft value")
        addSubview(changeMarker)
        textField = label
        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        labelLeading = leading
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            changeMarker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            changeMarker.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func setPresentation(changed: Bool, annotation: String?) {
        changeMarker.isHidden = !changed && annotation == nil
        changeMarker.stringValue = annotation == nil ? "•" : (changed ? "ƒ•" : "ƒ")
        labelLeading?.constant = annotation != nil && changed ? 18 : 10
        changeMarker.setAccessibilityLabel(annotation ?? "Local draft value")
        let details = [changed ? "Changed locally. Preview and Apply are required to update the database." : nil, annotation].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityHelp(details.isEmpty ? nil : details)
        if let annotation { toolTip = [toolTip, annotation].compactMap { $0 }.joined(separator: "\n") }
    }
    func configure(text: String, kind: Kind, alignment: NSTextAlignment, tooltip: String?) {
        guard let textField else { return }
        textField.stringValue = text
        textField.alignment = alignment
        textField.font = .monospacedSystemFont(ofSize: kind == .null ? 10 : 12, weight: kind == .null ? .medium : .regular)
        textField.textColor = switch kind {
        case .value: .labelColor
        case .null, .rowNumber: .secondaryLabelColor
        case .placeholder: .tertiaryLabelColor
        case .failed: .systemOrange
        }
        toolTip = tooltip
        setAccessibilityValue(kind == .null ? "Null value" : text)
    }
}
