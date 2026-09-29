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

    public init(
        columns: [DatabaseColumn],
        rowCount: Int,
        revision: Int,
        isActive: Bool = true,
        loadRows: @escaping @Sendable (Range<Int>) async throws -> [DatabaseRow],
        onSelect: (@MainActor (Int, DatabaseColumn, DatabaseValue) -> Void)? = nil
    ) {
        self.columns = columns
        self.rowCount = max(0, rowCount)
        self.revision = revision
        self.isActive = isActive
        self.loadRows = loadRows
        self.onSelect = onSelect
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

        let table = NSTableView()
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
        table.setAccessibilityHelp("Select a row or click a cell to inspect its complete value.")
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.action = #selector(Coordinator.cellClicked(_:))
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
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
        private static let byteLimit = 4 * 1_024 * 1_024
        private static let tileLimit = 12

        fileprivate init(parent: ResultsGrid) {
            self.parent = parent
            displayedRowCount = parent.rowCount
        }

        fileprivate func attach(table: NSTableView, scroll: NSScrollView) {
            self.table = table
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
            let wasActive = self.parent.isActive
            self.parent = parent
            needsResultReset = needsResultReset || reset
            if wasActive && !parent.isActive { cancelWork() }
            // Keep native selection, widths, and scroll untouched while hidden.
            // A background query may replace/append its result; apply only its
            // latest presentation when the owning worksheet becomes visible.
            guard !isStopped, parent.isActive, let table else { return }
            let previousCount = displayedRowCount
            displayedRowCount = parent.rowCount
            if needsResultReset {
                invalidate()
                rebuildColumns()
                table.deselectAll(nil)
                table.reloadData()
                needsResultReset = false
            } else if parent.rowCount != previousCount {
                // A partially filled tail page must be refetched when more rows
                // arrive. Complete pages keep their stable row identities.
                let tailPage = previousCount / TileKey.rowsPerTile
                for key in Array(cache.keys) where key.rowPage >= tailPage { removeCached(key) }
                failed.removeAll()
                table.noteNumberOfRowsChanged()
                if String(previousCount).count != String(parent.rowCount).count { columnLayoutDirty = true }
            }
            measureHeaders()
            scheduleColumnLayout()
            enqueueViewport()
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
            let numberWidth = min(120.0, max(48, Double(String(max(1, parent.rowCount)).count) * 8 + 20))
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
            scheduleColumnLayout()
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
            guard let tableColumn, row >= 0, row < parent.rowCount else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("result-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCell ?? ResultCell(identifier: identifier)
            guard tableColumn.identifier.rawValue != "row-number" else {
                cell.configure(text: String(row + 1), kind: .rowNumber, alignment: .right, tooltip: nil)
                return cell
            }
            guard let position = Int(tableColumn.identifier.rawValue.dropFirst(6)), position < parent.columns.count else { return cell }
            let alignment = parent.columns[position].resultAlignment
            let key = TileKey(row: row, column: position)
            if let tile = cache[key], let value = tile.value(row: row, column: position) {
                touch(key)
                cell.configure(text: value.text, kind: value.isNull ? .null : .value, alignment: alignment, tooltip: value.isTruncated ? "Preview shortened. Select this cell to inspect the full value." : nil)
            } else if failed.contains(key) {
                cell.configure(text: "Unable to load", kind: .failed, alignment: alignment, tooltip: "This result page could not be loaded.")
            } else {
                cell.configure(text: "…", kind: .placeholder, alignment: alignment, tooltip: nil)
                enqueue(key)
            }
            return cell
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            inspectSelection()
        }

        @objc fileprivate func cellClicked(_ table: NSTableView) {
            if table.clickedColumn > 0 { selectedColumn = table.clickedColumn - 1 }
            inspectSelection()
        }

        private func inspectSelection() {
            selectionTask?.cancel()
            selectionTask = nil
            guard !isStopped, parent.isActive, let table, table.selectedRow >= 0,
                  parent.columns.indices.contains(selectedColumn), let callback = parent.onSelect else { return }
            let row = table.selectedRow
            let position = selectedColumn
            let column = parent.columns[position]
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
            scheduleColumnLayout()
            enqueueViewport()
        }

        private func enqueueViewport() {
            guard !isStopped, parent.isActive, let table, parent.rowCount > 0 else { return }
            let rows = table.rows(in: table.visibleRect)
            guard rows.location != NSNotFound else { return }
            let lower = max(0, rows.location)
            let upper = min(parent.rowCount, max(lower + 1, NSMaxRange(rows)))
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
                  !pending.contains(key), pending.count < 16 else { return }
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
private final class ResultHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Add space around the native title without moving its border or divider.
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 8, dy: 0), in: controlView)
    }
}

@MainActor
private final class ResultCell: NSTableCellView {
    enum Kind { case value, null, placeholder, rowNumber, failed }
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
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
