import Foundation

public enum ScalarEditorKind: String, Sendable, Codable {
    case text, integer, decimal, floatingPoint, boolean, date, time, timestamp, uuid, json, enumeration
}

/// Adapter metadata is descriptive only; it never changes the SQL execution path.
public struct FieldEditorMetadata: Hashable, Sendable {
    public enum Classification: String, Sendable { case ordinary, storedComputed, storedDerived, nonstoredComputed, unresolved }
    public let classification: Classification
    public let modelField: String
    public let source: String
    public let revision: String
    public init(classification: Classification, modelField: String, source: String, revision: String) {
        self.classification = classification; self.modelField = modelField; self.source = source; self.revision = revision
    }
    public var requiresWarning: Bool { classification == .storedComputed || classification == .storedDerived }
    public static let directSQLWarning = "This value is computed by the application. Direct SQL does not run ORM recomputation, inverse methods, onchange behavior, or application validation, and may leave dependent values out of date."
}

public protocol FieldEditorMetadataProvider: Sendable {
    func prepare(databaseOID: UInt32, schemaOID: UInt32, relationOID: UInt32, schema: String, table: String, columns: [EditableColumn]) async
    func validatePreparedMetadata(relationOID: UInt32) async throws
    func metadata(relationOID: UInt32, attributeNumber: Int) async -> FieldEditorMetadata?
    func choices(relationOID: UInt32, attributeNumber: Int) async -> ValueChoiceSet?
}

public extension FieldEditorMetadataProvider {
    func prepare(databaseOID: UInt32, schemaOID: UInt32, relationOID: UInt32, schema: String, table: String, columns: [EditableColumn]) async {}
    func validatePreparedMetadata(relationOID: UInt32) async throws {}
    func choices(relationOID: UInt32, attributeNumber: Int) async -> ValueChoiceSet? { nil }
}

public struct EditableColumn: Hashable, Sendable {
    public let index: Int
    public let attributeNumber: Int
    public let name: String
    public let typeOID: UInt32
    public let typeSQL: String
    public let nullable: Bool
    public let kind: ScalarEditorKind?
    public let readOnlyReason: String?
    public let applicationMetadata: FieldEditorMetadata?
    public let insertReadOnlyReason: String?
    public let hasDefault: Bool
    public let valueChoices: ValueChoiceSet?
    public init(index: Int, attributeNumber: Int, name: String, typeOID: UInt32, typeSQL: String,
                nullable: Bool, kind: ScalarEditorKind?, readOnlyReason: String? = nil,
                applicationMetadata: FieldEditorMetadata? = nil, valueChoices: ValueChoiceSet? = nil,
                insertReadOnlyReason: String? = nil, hasDefault: Bool = false) {
        self.index = index; self.attributeNumber = attributeNumber; self.name = name; self.typeOID = typeOID
        self.typeSQL = typeSQL; self.nullable = nullable; self.kind = kind; self.readOnlyReason = readOnlyReason
        self.applicationMetadata = applicationMetadata
        self.valueChoices = valueChoices
        self.insertReadOnlyReason = insertReadOnlyReason; self.hasDefault = hasDefault
    }
    public var effectiveInsertReadOnlyReason: String? {
        if let insertReadOnlyReason { return insertReadOnlyReason }
        if kind == nil { return "This PostgreSQL type does not yet support safe editing." }
        if applicationMetadata?.classification == .nonstoredComputed { return "This computed field is not stored in the database." }
        if applicationMetadata?.classification == .unresolved { return "The application field metadata is unresolved." }
        return nil
    }
    public var effectiveReadOnlyReason: String? {
        if let readOnlyReason { return readOnlyReason }
        if kind == nil { return "This PostgreSQL type does not yet support safe editing." }
        if applicationMetadata?.classification == .nonstoredComputed { return "This computed field is not stored in the database." }
        if applicationMetadata?.classification == .unresolved { return "The application field metadata is unresolved." }
        return nil
    }
}

public struct EditableForeignKey: Hashable, Sendable, Identifiable {
    public let id: UInt32
    public let name: String
    public let localAttributes: [Int]
    public let targetRelationOID: UInt32
    public let targetSchema: String
    public let targetTable: String
    public let targetColumns: [EditableColumn]
    public let labelColumn: EditableColumn?
    public let unavailableReason: String?
    public init(id: UInt32, name: String, localAttributes: [Int], targetRelationOID: UInt32,
                targetSchema: String, targetTable: String, targetColumns: [EditableColumn],
                labelColumn: EditableColumn? = nil, unavailableReason: String? = nil) {
        self.id = id; self.name = name; self.localAttributes = localAttributes; self.targetRelationOID = targetRelationOID
        self.targetSchema = targetSchema; self.targetTable = targetTable; self.targetColumns = targetColumns
        self.labelColumn = labelColumn; self.unavailableReason = unavailableReason
    }
}

public struct EditableTable: Hashable, Sendable {
    public let relationOID: UInt32
    public let schema: String
    public let name: String
    public let columns: [EditableColumn]
    public let primaryKeyAttributes: [Int]
    public let foreignKeys: [EditableForeignKey]
    public let metadataRevision: String
    public let readOnlyReason: String?
    public let insertReadOnlyReason: String?
    public init(relationOID: UInt32, schema: String, name: String, columns: [EditableColumn], primaryKeyAttributes: [Int],
                foreignKeys: [EditableForeignKey] = [], metadataRevision: String, readOnlyReason: String? = nil, insertReadOnlyReason: String? = nil) {
        self.relationOID = relationOID; self.schema = schema; self.name = name; self.columns = columns
        self.primaryKeyAttributes = primaryKeyAttributes; self.foreignKeys = foreignKeys
        self.metadataRevision = metadataRevision; self.readOnlyReason = readOnlyReason
        self.insertReadOnlyReason = readOnlyReason ?? insertReadOnlyReason
    }
    public var quotedName: String { DatabaseObject.quoteIdentifier(schema) + "." + DatabaseObject.quoteIdentifier(name) }
    public var hiddenVersionIndex: Int { columns.count }
    public var databaseColumns: [DatabaseColumn] { columns.map { DatabaseColumn(index: $0.index, name: $0.name, typeOID: $0.typeOID, relationOID: relationOID, attributeNumber: $0.attributeNumber) } }
    public var primaryKeyColumns: [EditableColumn] { primaryKeyAttributes.compactMap { a in columns.first { $0.attributeNumber == a } } }
    /// The final position, never a displayed name, is the hidden version channel.
    public func selectSQL(limit: Int = 1000) -> String {
        let names = columns.map { DatabaseObject.quoteIdentifier($0.name) }.joined(separator: ", ")
        return "SELECT \(names), xmin::text\nFROM ONLY \(quotedName)\nORDER BY \(primaryKeyColumns.map { DatabaseObject.quoteIdentifier($0.name) }.joined(separator: ", "))\nLIMIT \(min(1000, max(1, limit)));"
    }
    public func snapshot(rowIndex: Int, fetchedRow: DatabaseRow) throws -> EditableRowSnapshot {
        guard fetchedRow.count == columns.count + 1, case .text(let version) = fetchedRow.last, UInt32(version) != nil else {
            throw DatabaseError("The editable result does not contain its original row-version token.")
        }
        return EditableRowSnapshot(rowIndex: rowIndex, values: Array(fetchedRow.dropLast()), version: version)
    }
}

public struct EditSourceContext: Hashable, Sendable {
    public let sessionID: UUID
    public let resultRevision: UUID
    public let transactionEpoch: UInt64
    public let relationOID: UInt32
    public let metadataRevision: String
    public init(sessionID: UUID, resultRevision: UUID, transactionEpoch: UInt64, relationOID: UInt32, metadataRevision: String) {
        self.sessionID = sessionID; self.resultRevision = resultRevision; self.transactionEpoch = transactionEpoch
        self.relationOID = relationOID; self.metadataRevision = metadataRevision
    }
}

public struct EditableRowSnapshot: Hashable, Sendable {
    public let rowIndex: Int
    public let values: DatabaseRow
    public let version: String
    public init(rowIndex: Int, values: DatabaseRow, version: String) { self.rowIndex = rowIndex; self.values = values; self.version = version }
    public var byteCount: Int { 64 + version.utf8.count + values.reduce(0) { $0 + $1.byteCount } }
}

public struct EditRowDraft: Hashable, Sendable, Identifiable {
    public var id: Int { original.rowIndex }
    public let original: EditableRowSnapshot
    public var replacements: [Int: DatabaseValue]
    public var acknowledgements: [Int: String]
    public var byteCount: Int { original.byteCount + replacements.reduce(0) { $0 + 32 + $1.value.byteCount } + acknowledgements.values.reduce(0) { $0 + $1.utf8.count + 32 } }
}

/// Missing entries use the database default; .null and .text("") are explicit values.
public struct InsertRowDraft: Hashable, Sendable, Identifiable {
    public let id: Int
    public var values: [Int: DatabaseValue]
    public var acknowledgements: [Int: String]
    public var byteCount: Int { 64 + values.reduce(0) { $0 + 32 + $1.value.byteCount } + acknowledgements.values.reduce(0) { $0 + $1.utf8.count + 32 } }
}

public struct EditParameter: Hashable, Sendable {
    public let value: DatabaseValue
    public let typeSQL: String
    public var text: String? { if case .text(let text) = value { text } else { nil } }
    public init(value: DatabaseValue, typeSQL: String) { self.value = value; self.typeSQL = typeSQL }
}

public struct EditStatement: Sendable {
    public let row: EditRowDraft?
    public let insertedRow: InsertRowDraft?
    public var isInsert: Bool { insertedRow != nil }
    public var rowIndex: Int { row?.id ?? insertedRow!.id }
    public let sql: String
    public let parameters: [EditParameter]
}

public struct EditPlan: Sendable, Identifiable {
    public let id: UUID
    public let context: EditSourceContext
    public let draftRevision: UInt64
    public let table: EditableTable
    public let mode: CommitMode
    public let environment: ConnectionEnvironment
    public let statements: [EditStatement]
    // Plans retain their reservation through copying and presentation.
    private let reservation: EditPayloadReservation
    fileprivate init(context: EditSourceContext, draftRevision: UInt64, table: EditableTable, mode: CommitMode,
                     environment: ConnectionEnvironment, statements: [EditStatement], bytes: Int) throws {
        id = UUID(); self.context = context; self.draftRevision = draftRevision; self.table = table
        self.mode = mode; self.environment = environment; self.statements = statements
        reservation = try EditPayloadReservation(bytes: bytes)
    }
}

public struct EditDraftState: Sendable {
    public let revision: UInt64
    public let rows: [EditRowDraft]
    public let insertRows: [InsertRowDraft]
    public let canUndo: Bool
    public let canRedo: Bool
    public var changedCellCount: Int { rows.reduce(0) { $0 + $1.replacements.count } + insertRows.reduce(0) { $0 + $1.values.count } }
    public var changedRowCount: Int { rows.count + insertRows.count }
    public var hasChanges: Bool { changedRowCount > 0 }
}

/// Shared budget accounts retained draft, originals, history and live preview plans.
private final class EditPayloadBudget: @unchecked Sendable {
    static let shared = EditPayloadBudget()
    private let lock = NSLock()
    private var owners: [UUID: Int] = [:]
    func set(_ id: UUID, bytes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, owners.values.reduce(0, +) - (owners[id] ?? 0) + bytes <= EditDraftStore.maximumPayloadBytes else {
            throw DatabaseError("The application-wide 8 MiB edit budget is full. Apply or discard drafts, or close an older preview.")
        }
        if bytes == 0 { owners[id] = nil } else { owners[id] = bytes }
    }
    func release(_ id: UUID) { lock.lock(); owners[id] = nil; lock.unlock() }
}
public final class EditPayloadReservation: @unchecked Sendable {
    let id = UUID()
    public init(bytes: Int = 0) throws { try EditPayloadBudget.shared.set(id, bytes: bytes) }
    public func resize(bytes: Int) throws { try EditPayloadBudget.shared.set(id, bytes: bytes) }
    deinit { EditPayloadBudget.shared.release(id) }
}

public actor EditDraftStore {
    public static let maximumRows = 1000
    public static let maximumValueBytes = 1024 * 1024
    public static let maximumPayloadBytes = 8 * 1024 * 1024
    private let budgetID = UUID()
    public let context: EditSourceContext
    public let table: EditableTable
    private var revision: UInt64 = 0
    private var drafts: [Int: EditRowDraft] = [:]
    private var insertDrafts: [Int: InsertRowDraft] = [:]
    private struct UndoEntry {
        let rowIndex: Int
        let before: EditRowDraft?
        let after: EditRowDraft?
        var beforeInsert: InsertRowDraft? = nil
        var afterInsert: InsertRowDraft? = nil
        var byteCount: Int { 32 + (before?.byteCount ?? 0) + (after?.byteCount ?? 0) + (beforeInsert?.byteCount ?? 0) + (afterInsert?.byteCount ?? 0) }
    }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    public init(context: EditSourceContext, table: EditableTable) { self.context = context; self.table = table }
    deinit { EditPayloadBudget.shared.release(budgetID) }
    public func state() -> EditDraftState {
        EditDraftState(revision: revision, rows: drafts.values.sorted { $0.id < $1.id }, insertRows: insertDrafts.values.sorted { $0.id < $1.id }, canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty)
    }
    public func stage(row: EditableRowSnapshot, columnIndex: Int, value: DatabaseValue, computedAcknowledgement: String? = nil) throws {
        try stage(row: row, replacements: [columnIndex: value], computedAcknowledgements: computedAcknowledgement.map { [columnIndex: $0] } ?? [:])
    }
    /// Composite foreign keys stage atomically as one undo step.
    public func stage(row: EditableRowSnapshot, replacements: [Int: DatabaseValue], computedAcknowledgements: [Int: String] = [:]) throws {
        if let reason = table.readOnlyReason { throw DatabaseError(reason) }
        guard context.relationOID == table.relationOID, context.metadataRevision == table.metadataRevision else { throw DatabaseError("The editing source does not match the table metadata.") }
        guard insertDrafts[row.rowIndex] == nil else { throw DatabaseError("A new row already uses this draft position.") }
        guard row.rowIndex >= 0, row.values.count == table.columns.count, UInt32(row.version) != nil else { throw DatabaseError("The original editable row is incomplete.") }
        if let original = drafts[row.rowIndex]?.original, original != row { throw DatabaseError("This row's original result changed. Review the draft before editing again.") }
        let key = table.primaryKeyColumns.map { row.values[$0.index] }
        if let duplicate = drafts.values.first(where: { existing in
            existing.id != row.rowIndex && table.primaryKeyColumns.map { existing.original.values[$0.index] } == key
        }) {
            throw DatabaseError("This primary key already has pending changes in result row \(duplicate.id + 1). Edit that row instead of staging a second copy of the same database row.")
        }
        var draft = drafts[row.rowIndex] ?? EditRowDraft(original: row, replacements: [:], acknowledgements: [:])
        for (index, value) in replacements {
            guard let column = table.columns.first(where: { $0.index == index }) else { throw DatabaseError("The edited column no longer exists.") }
            try Self.validate(value, column: column)
            if let metadata = column.applicationMetadata, metadata.requiresWarning {
                guard computedAcknowledgements[index] == metadata.revision || draft.acknowledgements[index] == metadata.revision else { throw DatabaseError(FieldEditorMetadata.directSQLWarning) }
                draft.acknowledgements[index] = metadata.revision
            }
            draft.replacements[index] = value == row.values[index] ? nil : value
        }
        var next = drafts
        next[row.rowIndex] = draft.replacements.isEmpty ? nil : draft
        guard next != drafts else { return }
        guard next.count + insertDrafts.count <= Self.maximumRows else { throw DatabaseError("At most 1,000 changed rows can be staged at once.") }
        let history = Array((undoStack + [UndoEntry(rowIndex: row.rowIndex, before: drafts[row.rowIndex], after: next[row.rowIndex])]).suffix(64))
        try reserve(next, undo: history, redo: [])
        drafts = next; undoStack = history; redoStack = []; revision &+= 1
    }
    /// Creating a row is itself a staged change, including DEFAULT VALUES inserts.
    public func addInsert(rowIndex: Int) throws {
        try validateInsertContext()
        guard rowIndex >= 0, drafts[rowIndex] == nil, insertDrafts[rowIndex] == nil else { throw DatabaseError("This draft row position is already in use.") }
        try saveInsert(InsertRowDraft(id: rowIndex, values: [:], acknowledgements: [:]), rowIndex: rowIndex)
    }
    public func stageInsert(rowIndex: Int, columnIndex: Int, value: DatabaseValue, computedAcknowledgement: String? = nil) throws {
        try stageInsert(rowIndex: rowIndex, replacements: [columnIndex: value], computedAcknowledgements: computedAcknowledgement.map { [columnIndex: $0] } ?? [:])
    }
    public func stageInsert(rowIndex: Int, replacements: [Int: DatabaseValue], computedAcknowledgements: [Int: String] = [:]) throws {
        try validateInsertContext()
        guard var draft = insertDrafts[rowIndex] else { throw DatabaseError("This new row is no longer staged.") }
        for (index, value) in replacements {
            guard let column = table.columns.first(where: { $0.index == index }) else { throw DatabaseError("The inserted column no longer exists.") }
            try Self.validate(value, column: column, inserting: true)
            if let metadata = column.applicationMetadata, metadata.requiresWarning {
                guard computedAcknowledgements[index] == metadata.revision || draft.acknowledgements[index] == metadata.revision else { throw DatabaseError(FieldEditorMetadata.directSQLWarning) }
                draft.acknowledgements[index] = metadata.revision
            }
            draft.values[index] = value
        }
        try saveInsert(draft, rowIndex: rowIndex)
    }
    public func useDefault(rowIndex: Int, columnIndex: Int) throws {
        try validateInsertContext()
        guard table.columns.indices.contains(columnIndex), var draft = insertDrafts[rowIndex] else { throw DatabaseError("This new row or column is no longer staged.") }
        draft.values[columnIndex] = nil; draft.acknowledgements[columnIndex] = nil
        try saveInsert(draft, rowIndex: rowIndex)
    }
    public func discardInsert(rowIndex: Int) throws { try saveInsert(nil, rowIndex: rowIndex) }
    private func validateInsertContext() throws {
        if let reason = table.insertReadOnlyReason { throw DatabaseError(reason) }
        guard context.relationOID == table.relationOID, context.metadataRevision == table.metadataRevision else { throw DatabaseError("The editing source does not match the table metadata.") }
    }
    private func saveInsert(_ draft: InsertRowDraft?, rowIndex: Int) throws {
        var next = insertDrafts; next[rowIndex] = draft
        guard next != insertDrafts else { return }
        guard next.count + drafts.count <= Self.maximumRows else { throw DatabaseError("At most 1,000 changed rows can be staged at once.") }
        let entry = UndoEntry(rowIndex: rowIndex, before: nil, after: nil, beforeInsert: insertDrafts[rowIndex], afterInsert: draft)
        let history = Array((undoStack + [entry]).suffix(64))
        try reserve(drafts, inserts: next, undo: history, redo: [])
        insertDrafts = next; undoStack = history; redoStack = []; revision &+= 1
    }
    /// Explicit conflict resolution: retain the desired changes, but establish
    /// a new checked baseline. The caller must show current/original/draft first.
    public func rebase(rowIndex: Int, onto row: EditableRowSnapshot) throws {
        guard let existing = drafts[rowIndex], row.rowIndex == rowIndex, row.values.count == table.columns.count,
              UInt32(row.version) != nil else { throw DatabaseError("The fresh row is unavailable or incomplete.") }
        guard table.primaryKeyColumns.allSatisfy({ row.values[$0.index] == existing.original.values[$0.index] }) else {
            throw DatabaseError("The fresh row has a different primary key. It cannot replace this draft's identity.")
        }
        var replacements = existing.replacements
        for (index, value) in replacements {
            try Self.validate(value, column: table.columns[index])
            if value == row.values[index] { replacements[index] = nil }
        }
        var next = drafts
        next[rowIndex] = replacements.isEmpty ? nil : EditRowDraft(original: row, replacements: replacements, acknowledgements: existing.acknowledgements)
        // Undo cannot restore the stale version token after deliberate rebasing.
        try reserve(next, undo: [], redo: [])
        drafts = next; undoStack = []; redoStack = []; revision &+= 1
    }
    public func discard(rowIndex: Int) throws {
        var next = drafts; next[rowIndex] = nil
        try reserve(next, undo: [], redo: [])
        drafts = next; undoStack = []; redoStack = []; revision &+= 1
    }
    public func undo() throws {
        guard let last = undoStack.last else { return }
        let undo = Array(undoStack.dropLast()), redo = redoStack + [last]
        var next = drafts; next[last.rowIndex] = last.before
        var inserts = insertDrafts; inserts[last.rowIndex] = last.beforeInsert
        try reserve(next, inserts: inserts, undo: undo, redo: redo)
        insertDrafts = inserts; drafts = next; undoStack = undo; redoStack = redo; revision &+= 1
    }
    public func redo() throws {
        guard let last = redoStack.last else { return }
        let redo = Array(redoStack.dropLast()), undo = undoStack + [last]
        var next = drafts; next[last.rowIndex] = last.after
        var inserts = insertDrafts; inserts[last.rowIndex] = last.afterInsert
        try reserve(next, inserts: inserts, undo: undo, redo: redo)
        insertDrafts = inserts; drafts = next; undoStack = undo; redoStack = redo; revision &+= 1
    }
    public func discard() { drafts = [:]; insertDrafts = [:]; undoStack = []; redoStack = []; revision &+= 1; EditPayloadBudget.shared.release(budgetID) }
    public func matches(_ plan: EditPlan) -> Bool { plan.context == context && plan.draftRevision == revision }
    public func makePlan(mode: CommitMode, environment: ConnectionEnvironment) throws -> EditPlan {
        guard mode != .auto || environment == .development else { throw DatabaseError("Automatic commit is available only for an explicitly classified development connection.") }
        guard table.readOnlyReason == nil, !table.primaryKeyColumns.isEmpty, (!drafts.isEmpty || !insertDrafts.isEmpty) else { throw DatabaseError(table.readOnlyReason ?? "There are no eligible pending changes to preview.") }
        var bytes = 0
        var statements = try drafts.values.sorted { a, b in
            let left = table.primaryKeyColumns.map { a.original.values[$0.index].displayText }
            let right = table.primaryKeyColumns.map { b.original.values[$0.index].displayText }
            return left.lexicographicallyPrecedes(right)
        }.map { draft -> EditStatement in
            var parameters: [EditParameter] = []
            func bind(_ value: DatabaseValue, _ type: String) -> String {
                parameters.append(EditParameter(value: value, typeSQL: type)); return "$\(parameters.count)::\(type)"
            }
            let changed = draft.replacements.keys.sorted()
            let assignments = try changed.map { index -> String in
                let column = table.columns[index], value = draft.replacements[index]!
                try Self.validate(value, column: column)
                return DatabaseObject.quoteIdentifier(column.name) + " = " + bind(value, column.typeSQL)
            }
            var predicates = table.primaryKeyColumns.map { DatabaseObject.quoteIdentifier($0.name) + " = " + bind(draft.original.values[$0.index], $0.typeSQL) }
            predicates.append("xmin = " + bind(.text(draft.original.version), "pg_catalog.xid"))
            for index in changed {
                let column = table.columns[index]
                predicates.append(DatabaseObject.quoteIdentifier(column.name) + " IS NOT DISTINCT FROM " + bind(draft.original.values[index], column.typeSQL))
            }
            let returned = table.columns.map { DatabaseObject.quoteIdentifier($0.name) }.joined(separator: ", ") + ", xmin::text"
            let sql = "UPDATE ONLY \(table.quotedName)\nSET \(assignments.joined(separator: ", "))\nWHERE \(predicates.joined(separator: "\n  AND "))\nRETURNING \(returned)"
            bytes += draft.byteCount + sql.utf8.count + parameters.reduce(0) { $0 + $1.value.byteCount + $1.typeSQL.utf8.count + 32 }
            guard bytes <= Self.maximumPayloadBytes else { throw DatabaseError("The edit preview exceeds the 8 MiB payload limit.") }
            return EditStatement(row: draft, insertedRow: nil, sql: sql, parameters: parameters)
        }
        if !insertDrafts.isEmpty { try validateInsertContext() }
        for draft in insertDrafts.values.sorted(by: { $0.id < $1.id }) {
            let missing = table.columns.filter { !$0.nullable && !$0.hasDefault && draft.values[$0.index] == nil }
            guard missing.isEmpty else { throw DatabaseError("Enter a value for required column(s): " + missing.map(\.name).joined(separator: ", ") + ".") }
            let indices = draft.values.keys.sorted()
            let parameters = try indices.map { index -> EditParameter in
                let column = table.columns[index], value = draft.values[index]!
                try Self.validate(value, column: column, inserting: true)
                return EditParameter(value: value, typeSQL: column.typeSQL)
            }
            let values: String
            if indices.isEmpty { values = "DEFAULT VALUES" }
            else {
                let names = indices.map { DatabaseObject.quoteIdentifier(table.columns[$0].name) }.joined(separator: ", ")
                let bindings = parameters.enumerated().map { "$\($0.offset + 1)::\($0.element.typeSQL)" }.joined(separator: ", ")
                values = "(\(names))\nVALUES (\(bindings))"
            }
            let returned = table.columns.map { DatabaseObject.quoteIdentifier($0.name) }.joined(separator: ", ") + ", xmin::text"
            let sql = "INSERT INTO \(table.quotedName)\n\(values)\nRETURNING \(returned)"
            bytes += draft.byteCount + sql.utf8.count + parameters.reduce(0) { $0 + $1.value.byteCount + $1.typeSQL.utf8.count + 32 }
            guard bytes <= Self.maximumPayloadBytes else { throw DatabaseError("The edit preview exceeds the 8 MiB payload limit.") }
            statements.append(EditStatement(row: nil, insertedRow: draft, sql: sql, parameters: parameters))
        }
        return try EditPlan(context: context, draftRevision: revision, table: table, mode: mode, environment: environment, statements: statements, bytes: bytes)
    }
    private func reserve(_ rows: [Int: EditRowDraft], inserts: [Int: InsertRowDraft]? = nil, undo: [UndoEntry], redo: [UndoEntry]) throws {
        let bytes = rows.values.reduce(0) { $0 + $1.byteCount } + (inserts ?? insertDrafts).values.reduce(0) { $0 + $1.byteCount } + (undo + redo).reduce(0) { $0 + $1.byteCount }
        try EditPayloadBudget.shared.set(budgetID, bytes: bytes)
    }
    public static func validate(_ value: DatabaseValue, column: EditableColumn, inserting: Bool = false) throws {
        if let reason = inserting ? column.effectiveInsertReadOnlyReason : column.effectiveReadOnlyReason { throw DatabaseError(reason) }
        guard value.byteCount <= maximumValueBytes else { throw DatabaseError("This value exceeds the 1 MiB inline editing limit.") }
        if value == .null { guard column.nullable else { throw DatabaseError("This column does not allow NULL.") }; return }
        guard case .text(let text) = value, !text.utf8.contains(0) else { throw DatabaseError("PostgreSQL text values cannot contain a NUL character.") }
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        let valid: Bool
        switch column.kind {
        case .text: valid = true
        case .enumeration: valid = column.valueChoices?.isAuthoritative == true && column.valueChoices?.contains(key: text) == true
        case .boolean: valid = ["true", "false", "t", "f"].contains(text)
        case .integer:
            if let integer = Int64(text), matches("^[+-]?[0-9]+$") {
                valid = column.typeOID == 21 ? (Int64(Int16.min)...Int64(Int16.max)).contains(integer) : column.typeOID == 23 ? (Int64(Int32.min)...Int64(Int32.max)).contains(integer) : true
            } else { valid = false }
        case .decimal, .floatingPoint: valid = matches("^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$") || ["NaN", "Infinity", "-Infinity"].contains(text)
        case .uuid: valid = UUID(uuidString: text) != nil
        case .date: valid = matches("^[0-9]{4,}-[0-9]{2}-[0-9]{2}$") || ["infinity", "-infinity"].contains(text)
        case .time: valid = matches("^[0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\\.[0-9]+)?)?(?:[+-][0-9]{2}(?::?[0-9]{2})?)?$")
        case .timestamp: valid = matches("^[0-9]{4,}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}(?::?[0-9]{2})?)?$") || ["infinity", "-infinity"].contains(text)
        case .json: valid = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
        case nil: valid = false
        }
        guard valid else { throw DatabaseError("Enter a valid \(column.kind?.rawValue ?? "supported") value. PostgreSQL validates remaining constraints when changes are applied.") }
    }
}

public struct EditApplyResult: Sendable {
    public let rows: [Int: EditableRowSnapshot]
    public let transaction: TransactionState
    public let committed: Bool
    private let reservation: EditPayloadReservation?
    public init(rows: [Int: EditableRowSnapshot], transaction: TransactionState, committed: Bool, reservation: EditPayloadReservation? = nil) {
        self.rows = rows; self.transaction = transaction; self.committed = committed; self.reservation = reservation
    }
}

public struct EditConflict: Error, LocalizedError, Sendable {
    public static let maximumFreshRowBytes = 2 * 1024 * 1024
    public let row: EditRowDraft
    public let freshRow: EditableRowSnapshot?
    public let comparisonUnavailableReason: String?
    public var comparisonUnavailable: Bool { freshRow == nil }
    public var freshValues: DatabaseRow? { freshRow?.values }
    // Copies of the error share one reservation until the final comparison closes.
    private let reservation: EditPayloadReservation?
    public var errorDescription: String? { "A row changed, disappeared, or could not be updated. The entire apply batch was rolled back. Review the original, draft, and current values before trying again." }
    public init(row: EditRowDraft, freshRow: EditableRowSnapshot?) {
        self.row = row
        guard let freshRow else {
            self.freshRow = nil; reservation = nil
            comparisonUnavailableReason = "The current row could not be fetched or is no longer visible."
            return
        }
        guard freshRow.byteCount <= Self.maximumFreshRowBytes,
              let reservation = try? EditPayloadReservation(bytes: freshRow.byteCount) else {
            self.freshRow = nil; reservation = nil
            comparisonUnavailableReason = "The current row could not be retained within the edit comparison memory budget."
            return
        }
        self.freshRow = freshRow; self.reservation = reservation
        comparisonUnavailableReason = nil
    }
}

public struct ForeignKeyCandidate: Hashable, Sendable, Identifiable {
    public var id: [DatabaseValue] { key }
    public let key: [DatabaseValue]
    public let label: String?
    public init(key: [DatabaseValue], label: String?) { self.key = key; self.label = label }
}
public struct ForeignKeyPage: Sendable {
    public let candidates: [ForeignKeyCandidate]
    public let nextCursor: [DatabaseValue]?
    public init(candidates: [ForeignKeyCandidate], nextCursor: [DatabaseValue]?) { self.candidates = candidates; self.nextCursor = nextCursor }
}
