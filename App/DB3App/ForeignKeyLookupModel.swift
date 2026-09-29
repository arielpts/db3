import Foundation
import Observation
import DB3Core
import DB3Postgres

@MainActor @Observable
final class ForeignKeyLookupModel: Identifiable {
    let id = UUID()
    let foreignKey: EditableForeignKey
    let table: EditableTable
    let row: EditableRowSnapshot
    let insertRowID: Int?
    let context: EditSourceContext
    var search = "" { didSet { if oldValue != search { load() } } }
    private(set) var candidates: [ForeignKeyCandidate] = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var hasMore = false
    private(set) var limited = false
    var selectedID: [DatabaseValue]?
    @ObservationIgnored private let coordinator: ManagedSession
    @ObservationIgnored private let metadataProvider: (any FieldEditorMetadataProvider)?
    @ObservationIgnored private let onFatalError: @MainActor (DatabaseError) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cursor: [DatabaseValue]?
    init(foreignKey: EditableForeignKey, table: EditableTable, row: EditableRowSnapshot,
         context: EditSourceContext, coordinator: ManagedSession, metadataProvider: (any FieldEditorMetadataProvider)? = nil,
         insertRowID: Int? = nil,
         onFatalError: @escaping @MainActor (DatabaseError) -> Void = { _ in }) {
        self.foreignKey = foreignKey; self.table = table; self.row = row; self.context = context; self.coordinator = coordinator
        self.metadataProvider = metadataProvider
        self.insertRowID = insertRowID
        self.onFatalError = onFatalError
    }
    var nullable: Bool {
        foreignKey.localAttributes.allSatisfy { attribute in table.columns.first { $0.attributeNumber == attribute }?.nullable == true }
    }
    func load(append: Bool = false) {
        if append && (!hasMore || busy || limited) { return }
        let previous = task; previous?.cancel()
        let token = UUID(); generation = token
        let search = search, after = append ? cursor : nil
        busy = true; error = nil
        if !append { candidates = []; cursor = nil; hasMore = false; limited = false; selectedID = nil }
        task = Task {
            await previous?.value
            do {
                if !append { try await Task.sleep(for: .milliseconds(200)) }
                try Task.checkCancellation()
                let fk = foreignKey, table = table, provider = metadataProvider
                let page = try await coordinator.withExclusiveOperation { session in
                    try await PostgresTableEditing.lookup(foreignKey: fk, table: table, search: search, cursor: after, on: session, metadataProvider: provider)
                }
                guard generation == token, !Task.isCancelled else { return }
                var result = append ? candidates : []
                var bytes = result.reduce(0) { $0 + Self.bytes($1) }
                for candidate in page.candidates where !result.contains(where: { $0.id == candidate.id }) {
                    guard result.count < 500, bytes + Self.bytes(candidate) <= 2 * 1024 * 1024 else { limited = true; break }
                    result.append(candidate); bytes += Self.bytes(candidate)
                }
                candidates = result; cursor = page.nextCursor; hasMore = cursor != nil
                if candidates.count >= 500 && hasMore { limited = true }
                busy = false; task = nil
            } catch {
                // Cancellation still must report a failed protocol/savepoint
                // recovery, even after a newer search invalidates this page.
                if let failure = error as? DatabaseError, failure.connectionLost { onFatalError(failure) }
                guard generation == token else { return }
                self.error = error is CancellationError ? nil : error.localizedDescription
                busy = false; task = nil
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); busy = false }
    func waitUntilIdle() async { await task?.value }
    private static func bytes(_ value: ForeignKeyCandidate) -> Int { value.key.reduce(64) { $0 + $1.byteCount } + (value.label?.utf8.count ?? 0) }
}

extension Worksheet {
    func chooseReference(row: Int, column resultIndex: Int) {
        guard canEditValues, lookup == nil, let table = editableTable, let context = editContext, let coordinator = managedSession,
              let index = canonicalColumn(resultIndex),
              let column = table.columns.first(where: { $0.index == index }) else { return }
        let matches = table.foreignKeys.filter { $0.localAttributes.contains(column.attributeNumber) }
        guard matches.count == 1, let fk = matches.first else { error = "This column participates in overlapping relationships. Edit the complete key manually."; return }
        if let reason = fk.unavailableReason { error = reason; return }
        Task {
            do {
                try await cellEditor.finish()
                let insertion = insertDraft(at: row)
                let snapshot: EditableRowSnapshot
                if let insertion {
                    snapshot = EditableRowSnapshot(rowIndex: insertion.id,
                        values: table.columns.map { insertion.values[$0.index] ?? .null }, version: "0")
                } else {
                    snapshot = try await editableRow(at: row)
                }
                guard context == editContext, canEditValues, lookup == nil else { return }
                let lookup = ForeignKeyLookupModel(foreignKey: fk, table: table, row: snapshot, context: context, coordinator: coordinator,
                    metadataProvider: metadataProvider, insertRowID: insertion?.id, onFatalError: { [weak self] failure in
                        guard let self, self.editContext == context, !self.isClosing, !self.isClosed else { return }
                        self.invalidateEditableSnapshot(); self.show(failure)
                    })
                self.lookup = lookup; lookup.load()
            } catch { show(error) }
        }
    }
    func closeLookup() {
        guard let old = lookup else { return }
        old.cancel()
        Task { await old.waitUntilIdle(); if lookup === old { lookup = nil; clearVerifiedEditRow() } }
    }
    func stageReference(_ candidate: ForeignKeyCandidate?, from picker: ForeignKeyLookupModel) {
        guard lookup === picker, editContext == picker.context, canEditValues, let drafts = draftStore else { return }
        picker.cancel()
        Task {
            await picker.waitUntilIdle()
            do {
                guard lookup === picker, editContext == picker.context, canEditValues else { return }
                let keys = candidate?.key ?? Array(repeating: DatabaseValue.null, count: picker.foreignKey.localAttributes.count)
                guard keys.count == picker.foreignKey.localAttributes.count else { throw DatabaseError("The referenced key is incomplete.") }
                var replacements: [Int: DatabaseValue] = [:]
                for (attribute, value) in zip(picker.foreignKey.localAttributes, keys) {
                    guard let column = picker.table.columns.first(where: { $0.attributeNumber == attribute }) else { throw DatabaseError("A foreign-key column no longer exists.") }
                    if let metadata = column.applicationMetadata, metadata.requiresWarning, computedAcknowledgements[column.index] != metadata.revision {
                        try await acknowledgeComputedColumn(column, context: picker.context)
                    }
                    replacements[column.index] = value
                }
                guard lookup === picker, editContext == picker.context, draftStore === drafts, canEditValues else { return }
                if let rowID = picker.insertRowID {
                    guard insertRows.contains(where: { $0.id == rowID }) else { throw DatabaseError("This new row is no longer available.") }
                    try await drafts.stageInsert(rowIndex: rowID, replacements: replacements, computedAcknowledgements: computedAcknowledgements)
                } else {
                    try await drafts.stage(row: picker.row, replacements: replacements, computedAcknowledgements: computedAcknowledgements)
                }
                guard lookup === picker, editContext == picker.context, draftStore === drafts, canEditValues else { return }
                await publishDrafts(drafts)
                if lookup === picker { lookup = nil }
            } catch { show(error) }
        }
    }
}
