import Foundation
import DB3Core
import DB3Grid

extension Worksheet {
    /// Inserts belong to the explicit full-table editing result. An arbitrary
    /// SELECT may omit required fields or have predicates that hide a new row.
    var insertionRow: Int? {
        guard editTarget != nil, editBaselineValid, !resultIncomplete,
              let table = editableTable, table.insertReadOnlyReason == nil,
              let projection = editProjection, projection.hasHiddenVersion,
              projection.resultToTable == table.columns.map({ Optional($0.index) }) else { return nil }
        return rowCount + insertRows.count
    }

    var additionalGridRows: Int { insertRows.count + (insertionRow == nil ? 0 : 1) }

    func insertDraft(at row: Int) -> InsertRowDraft? {
        let offset = row - rowCount
        return insertRows.indices.contains(offset) ? insertRows[offset] : nil
    }

    func createInsert(preferredColumn: Int) async throws -> Int {
        guard canEditValues, insertionRow != nil, let table = editableTable,
              let drafts = draftStore, let context = editContext else {
            throw DatabaseError("Open and run Edit Table Data before inserting a row.")
        }
        let nextID = max(rowCount, (insertRows.last?.id ?? (rowCount - 1)) + 1)
        try await drafts.addInsert(rowIndex: nextID)
        guard draftStore === drafts, editContext == context, canEditValues else { throw CancellationError() }
        await publishDrafts(drafts)
        let editable = columns.indices.filter { index in
            guard let canonical = canonicalColumn(index), table.columns.indices.contains(canonical) else { return false }
            return table.columns[canonical].effectiveInsertReadOnlyReason == nil
        }
        return editable.contains(preferredColumn) ? preferredColumn : (editable.first ?? -1)
    }

    func insertionPresentation(row: Int, column resultIndex: Int) -> GridCellPresentation {
        if row == insertionRow {
            return GridCellPresentation(value: .text(""), annotation: "Double-click to insert a row")
        }
        guard let draft = insertDraft(at: row), let table = editableTable,
              let canonical = canonicalColumn(resultIndex), table.columns.indices.contains(canonical) else {
            return GridCellPresentation(value: .text(""), readOnlyReason: "This new row is no longer available.")
        }
        let column = table.columns[canonical]
        let reason = !editBaselineValid ? "This snapshot is no longer editable. Discard drafts and run the table query again." : table.insertReadOnlyReason ?? column.effectiveInsertReadOnlyReason
        let value = draft.values[canonical]
        let annotation = value == nil ? (column.hasDefault ? "New row · Database default" : column.nullable ? "New row · Defaults to NULL" : "New row · Required value") : "New row · Pending insert"
        return GridCellPresentation(value: value ?? .text("DEFAULT"), isChanged: true, readOnlyReason: reason, annotation: annotation)
    }

    func loadInsertCellEditor(row: Int, column resultIndex: Int) async throws -> GridCellEdit {
        guard canEditValues, let draft = insertDraft(at: row), let table = editableTable,
              let canonical = canonicalColumn(resultIndex), table.columns.indices.contains(canonical) else {
            throw DatabaseError("This new row is no longer editable.")
        }
        let column = table.columns[canonical]
        if let reason = table.insertReadOnlyReason ?? column.effectiveInsertReadOnlyReason { throw DatabaseError(reason) }
        let context = editContext
        try await acknowledgeComputedColumn(column, context: context)
        try Task.checkCancellation()
        guard context == editContext, canEditValues, insertDraft(at: row)?.id == draft.id else { throw CancellationError() }
        let value = draft.values[canonical] ?? .null
        let kind: GridCellEdit.Kind = column.kind == .boolean ? .boolean : column.kind == .json ? .multiline : .scalar
        return GridCellEdit(value: value, kind: kind, nullable: column.nullable,
            label: "\(column.name), new row \(row - rowCount + 1)",
            canChooseReference: table.foreignKeys.contains { $0.localAttributes.contains(column.attributeNumber) },
            choices: column.valueChoices, usesDefault: draft.values[canonical] == nil, canUseDefault: true)
    }

    func stageInsertCell(row: Int, column resultIndex: Int, value: DatabaseValue) async throws {
        guard canEditValues, let draft = insertDraft(at: row), let drafts = draftStore,
              let context = editContext, let canonical = canonicalColumn(resultIndex) else {
            throw DatabaseError("This new row is no longer editable.")
        }
        try await drafts.stageInsert(rowIndex: draft.id, replacements: [canonical: value], computedAcknowledgements: computedAcknowledgements)
        guard context == editContext, draftStore === drafts else { throw CancellationError() }
        await publishDrafts(drafts)
    }

    func stageDefault(row: Int, column resultIndex: Int) async throws {
        guard canEditValues, let draft = insertDraft(at: row), let drafts = draftStore,
              let context = editContext, let canonical = canonicalColumn(resultIndex) else {
            throw DatabaseError("Database defaults can be selected only for a new row.")
        }
        try await drafts.useDefault(rowIndex: draft.id, columnIndex: canonical)
        guard context == editContext, draftStore === drafts else { throw CancellationError() }
        await publishDrafts(drafts)
    }
}
