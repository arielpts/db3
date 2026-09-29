import AppKit
import Foundation
import DB3Core
import DB3Grid
import DB3Postgres
import DB3Results

struct WorksheetEditTarget: Equatable, Sendable {
    let relationOID: UInt32
    let schema: String
    let name: String
    var initialSQL: String {
        "SELECT *, xmin::text\nFROM ONLY \(DatabaseObject.quoteIdentifier(schema)).\(DatabaseObject.quoteIdentifier(name))\nLIMIT 1000;"
    }
}

extension Worksheet {
    var hasGridDrafts: Bool { !draftRows.isEmpty || !insertRows.isEmpty }
    var hasPendingGridWork: Bool { hasActiveCellEditor || hasGridDrafts || lookup != nil }
    var environment: ConnectionEnvironment { managedSession?.effectiveEnvironment ?? profile?.environment ?? .unknown }
    var changedCellCount: Int { draftRows.reduce(0) { $0 + $1.replacements.count } + insertRows.reduce(0) { $0 + max(1, $1.values.count) } }
    var canEditValues: Bool { canIssueCommands && isConnected && !isBusy && editBaselineValid && transaction != .failed && !resultIncomplete }

    func prepareQueryEditing(sql: String, token: UUID) async throws {
        queryEditReadOnlyReason = "Include the complete primary key from one base table to edit these results."
        let relations = Set(columns.compactMap(\.relationOID).filter { $0 != 0 })
        guard relations.count == 1, let relation = relations.first, let coordinator = managedSession else { return }
        let parsing = Task.detached { try SQLDirectTableSelect.isEligible(sql) }
        let eligible = try await withTaskCancellationHandler { try await parsing.value } onCancel: { parsing.cancel() }
        guard generation == token, !isClosing, !isClosed else { throw CancellationError() }
        guard eligible else {
            queryEditReadOnlyReason = "Direct editing needs a SELECT from one base table with its complete primary key. Joins and grouped queries remain read-only."
            return
        }
        do {
            let provider = metadataProvider
            let table = try await coordinator.withExclusiveOperation { session in
                try await PostgresTableEditing.describe(relationOID: relation, on: session, metadataProvider: provider)
            }
            guard generation == token, !isClosing, !isClosed else { throw CancellationError() }
            if let reason = table.readOnlyReason { queryEditReadOnlyReason = reason; return }
            let projection = try ResultEditProjection(table: table, columns: columns)
            editableTable = table; editProjection = projection; queryEditReadOnlyReason = nil
        } catch {
            if error is CancellationError || (error as? DatabaseError)?.connectionLost == true { throw error }
            queryEditReadOnlyReason = error.localizedDescription
        }
    }

    func canonicalColumn(_ resultColumn: Int) -> Int? {
        guard let projection = editProjection else { return resultColumn }
        return projection.resultToTable.indices.contains(resultColumn) ? projection.resultToTable[resultColumn] : nil
    }

    func clearVerifiedEditRow() { verifiedEditRow = nil; verifiedEditReservation = nil }
    func setCellEditorActive(_ active: Bool) {
        hasActiveCellEditor = active
        if !active, lookup == nil { clearVerifiedEditRow() }
    }

    func restrictEnvironment(to value: ConnectionEnvironment) {
        if value == .production || pendingEnvironmentRestriction == .production { pendingEnvironmentRestriction = .production }
        else if value == .unknown || pendingEnvironmentRestriction == .unknown { pendingEnvironmentRestriction = .unknown }
        guard let managedSession else { return }
        managedSession.restrictEnvironment(to: value)
        if !managedSession.effectiveEnvironment.allowsAutoCommit {
            if commitMode == .auto { operation?.cancel() }
            commitMode = .manual; previewPlan = nil
        }
    }

    func updateTransaction(_ state: TransactionState) {
        if state == .inTransaction || state == .failed {
            if transactionStartedAt == nil { transactionStartedAt = Date() }
        } else { transactionStartedAt = nil }
        transaction = state
    }

    func invalidateEditableSnapshot() {
        editBaselineValid = false; previewPlan = nil; computedAcknowledgements = [:]
        clearVerifiedEditRow()
        lookup?.cancel(); lookup = nil
        editPresentationRevision &+= 1
    }

    func setCommitMode(_ mode: CommitMode) {
        guard canIssueCommands, !isBusy, isConnected, let managedSession else { return }
        guard !hasPendingGridWork else { error = "Apply or discard grid drafts before changing commit mode."; return }
        isBusy = true
        operation = Task {
            defer { isBusy = false; operation = nil }
            do {
                try await managedSession.validateModeChange(to: mode)
                guard !isClosing, !isClosed else { return }
                commitMode = mode; previewPlan = nil
            } catch { show(error) }
        }
    }

    func gridPresentation(row: Int, column: Int) -> GridCellPresentation? {
        if row >= rowCount { return insertionPresentation(row: row, column: column) }
        let draft = draftRows.first { $0.id == row }
        let canonical = canonicalColumn(column)
        let overlay = canonical.flatMap { draft?.replacements[$0] }
        let reason: String?
        if let table = editableTable {
            if !editBaselineValid { reason = "This snapshot is no longer editable. Run the table query again." }
            else if canonical == nil { reason = editExpressionsNeedRefresh ? "Calculated values are read-only. Run the query again to refresh them after edits." : "This calculated expression is read-only." }
            else { reason = table.readOnlyReason ?? table.columns.first { $0.index == canonical }?.effectiveReadOnlyReason }
        } else { reason = queryEditReadOnlyReason ?? "Include the complete primary key from one base table to edit these results." }
        let metadata = editableTable?.columns.first { $0.index == canonical }?.applicationMetadata
        let annotation = metadata.map { "\($0.classification.rawValue) · \($0.modelField) · \($0.source)" }
        return GridCellPresentation(value: overlay, isChanged: overlay != nil, readOnlyReason: reason, annotation: annotation)
    }

    func editableRow(at row: Int) async throws -> EditableRowSnapshot {
        guard let table = editableTable, let context = editContext, editBaselineValid else {
            throw DatabaseError("Run the table query again before editing.")
        }
        if let draft = draftRows.first(where: { $0.id == row }) { return draft.original }
        if let verified = verifiedEditRow, verified.rowIndex == row { return verified }
        let values = try await store.rows(in: row..<(row + 1))
        try Task.checkCancellation()
        guard context == editContext, editBaselineValid, let value = values.first else { throw DatabaseError("The edited result changed.") }
        if let projection = editProjection, !projection.hasHiddenVersion {
            guard let coordinator = managedSession else { throw DatabaseError("Reconnect before editing this result.") }
            let provider = metadataProvider
            let verified: EditableRowSnapshot
            do {
                verified = try await coordinator.withExclusiveOperation { session in
                    try await PostgresTableEditing.verifyProjectedRow(table: table, projection: projection, rowIndex: row, row: value, on: session, metadataProvider: provider)
                }
            } catch {
                if (error as? DatabaseError)?.connectionLost == true { invalidateEditableSnapshot(); show(error) }
                throw error
            }
            try Task.checkCancellation()
            guard context == editContext, canEditValues else { throw DatabaseError("The edited result changed.") }
            let reservation = try EditPayloadReservation(bytes: verified.byteCount)
            verifiedEditRow = verified; verifiedEditReservation = reservation
            return verified
        }
        return try table.snapshot(rowIndex: row, fetchedRow: value)
    }

    func loadCellEditor(row: Int, column resultIndex: Int) async throws -> GridCellEdit {
        if row >= rowCount { return try await loadInsertCellEditor(row: row, column: resultIndex) }
        guard canEditValues, let table = editableTable, let index = canonicalColumn(resultIndex),
              let column = table.columns.first(where: { $0.index == index }) else {
            throw DatabaseError(gridPresentation(row: row, column: resultIndex)?.readOnlyReason ?? "This cell is not editable while work is running.")
        }
        if let reason = column.effectiveReadOnlyReason { throw DatabaseError(reason) }
        let context = editContext
        let snapshot = try await editableRow(at: row)
        let value = draftRows.first { $0.id == row }?.replacements[index] ?? snapshot.values[index]
        guard value.byteCount <= EditDraftStore.maximumValueBytes else { throw DatabaseError("This value exceeds the 1 MiB editing limit. It remains available for inspection and copying.") }
        try await acknowledgeComputedColumn(column, context: context)
        let kind: GridCellEdit.Kind
        if column.kind == .boolean { kind = .boolean }
        else if column.kind == .json || value.displayText.contains("\n") || value.byteCount > 512 { kind = .multiline }
        else { kind = .scalar }
        try Task.checkCancellation()
        guard context == editContext, canEditValues else { throw DatabaseError("The edited source changed.") }
        return GridCellEdit(value: value, kind: kind, nullable: column.nullable,
            label: "\(column.name), row \(row + 1)", canChooseReference: table.foreignKeys.contains { $0.localAttributes.contains(column.attributeNumber) }, choices: column.valueChoices)
    }

    func acknowledgeComputedColumn(_ column: EditableColumn, context: EditSourceContext?) async throws {
        if let metadata = column.applicationMetadata, metadata.requiresWarning,
           computedAcknowledgements[column.index] != metadata.revision {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Edit a computed value?"
            alert.informativeText = FieldEditorMetadata.directSQLWarning + "\n\n\(metadata.modelField) · \(metadata.source)"
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Edit stored value")
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { throw CancellationError() }
            guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else { throw CancellationError() }
            guard context == editContext, canEditValues else { throw DatabaseError("The edited source changed.") }
            computedAcknowledgements[column.index] = metadata.revision
        }
    }

    func stageCell(row: Int, column resultIndex: Int, value: DatabaseValue) async throws {
        if row >= rowCount { try await stageInsertCell(row: row, column: resultIndex, value: value); return }
        guard canEditValues, let drafts = draftStore, let context = editContext, let column = canonicalColumn(resultIndex) else { throw DatabaseError("This cell is read-only or its editable snapshot is no longer current.") }
        let snapshot = try await editableRow(at: row)
        try await drafts.stage(row: snapshot, columnIndex: column, value: value, computedAcknowledgement: computedAcknowledgements[column])
        guard context == editContext, draftStore === drafts else { throw DatabaseError("The edited result changed.") }
        await publishDrafts(drafts)
    }

    func publishDrafts(_ drafts: EditDraftStore) async {
        let state = await drafts.state()
        guard draftStore === drafts else { return }
        draftRows = state.rows; insertRows = state.insertRows; draftRevision = state.revision
        canUndoDraft = state.canUndo; canRedoDraft = state.canRedo
        clearVerifiedEditRow()
        previewPlan = nil; editConflict = nil; editPresentationRevision &+= 1
    }

    func undoGridEdit(redo: Bool = false) {
        guard canEditValues, !hasActiveCellEditor, let drafts = draftStore else { return }
        Task {
            do { if redo { try await drafts.redo() } else { try await drafts.undo() }; await publishDrafts(drafts) }
            catch { show(error) }
        }
    }

    func discardGridDrafts() {
        guard canIssueCommands, !isBusy else { return }
        let oldLookup = lookup, drafts = draftStore, token = UUID()
        cellEditor.cancel(); oldLookup?.cancel(); previewPlan = nil
        generation = token; isBusy = true; isCancelling = false
        operation = Task {
            defer { if generation == token { isBusy = false; isCancelling = false; operation = nil } }
            // Keep the worksheet blocked until the canceled lookup has drained
            // its protocol messages and recovered its savepoint.
            await oldLookup?.waitUntilIdle()
            guard generation == token, !isClosing, !isClosed else { return }
            if lookup === oldLookup { lookup = nil }
            if let drafts { await drafts.discard(); await publishDrafts(drafts) }
            else { draftRows = []; insertRows = [] }
        }
    }

    func previewChanges() {
        guard canIssueCommands, !isBusy else { return }
        Task {
            do {
                try await cellEditor.finish()
                lookup?.cancel(); await lookup?.waitUntilIdle(); lookup = nil; clearVerifiedEditRow()
                guard canEditValues, let drafts = draftStore else { throw DatabaseError("Run the table query again before previewing edits.") }
                let context = editContext, mode = commitMode, environment = environment
                let plan = try await drafts.makePlan(mode: mode, environment: environment)
                guard context == editContext, mode == commitMode, await drafts.matches(plan), canEditValues else { throw DatabaseError("The drafts changed. Preview them again.") }
                previewPlan = plan
            } catch { show(error) }
        }
    }

    func applyPreview(_ plan: EditPlan) {
        guard canEditValues, !hasActiveCellEditor, let drafts = draftStore, let coordinator = managedSession,
              let context = editContext, plan.context == context, plan.id == previewPlan?.id,
              plan.mode == commitMode, plan.environment == environment else { error = "The preview is out of date. Preview changes again."; return }
        let oldStore = store, count = rowCount, token = UUID(), environment = environment
        let provider = metadataProvider, projection = editProjection
        let fence = projectMutationFence, projectVersion = projectMutationFence.current()
        let nextStore = Self.makeStore(allowsSpooling: allowsSpooling)
        generation = token; isBusy = true; isApplyingEdits = true; isCancelling = false; error = nil; status = "Applying changes…"
        operation = Task {
            defer { isApplyingEdits = false; if generation == token { isBusy = false; isCancelling = false; operation = nil } }
            do {
                guard await drafts.matches(plan) else { throw DatabaseError("The draft changed after preview.") }
                let result = try await coordinator.withExclusiveOperation { session in
                    try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: environment,
                        prepareResult: { replacements in
                            try fence.validate(projectVersion)
                            try await Self.copyEditingResult(from: oldStore, into: nextStore, count: count, replacements: replacements, table: plan.table, projection: projection,
                                insertedRowIDs: Set(plan.statements.compactMap { $0.insertedRow?.id }))
                            try fence.validate(projectVersion)
                        }, metadataProvider: provider, authorizeAutoCommit: {
                            try fence.validate(projectVersion); try coordinator.authorizeAutoCommit()
                        })
                }
                guard generation == token, !isClosing, !isClosed else { await nextStore.close(); return }
                let nextCount = await nextStore.rowCount()
                guard generation == token, !isClosing, !isClosed else { await nextStore.close(); return }
                store = nextStore; rowCount = nextCount; revision &+= 1
                await oldStore.close()
                await drafts.discard(); await publishDrafts(drafts)
                previewPlan = nil; updateTransaction(result.transaction)
                editExpressionsNeedRefresh = projection?.hasExpressions == true
                if result.committed { transactionEpoch &+= 1; invalidateEditableSnapshot() }
                status = result.committed ? "Committed — reload to edit" : "Applied — not committed"
                message = result.committed ? "The development edit batch committed. Run the table query again for a fresh snapshot." : "Applied \(plan.statements.count) row changes. Commit or Rollback acts on the entire worksheet transaction."
            } catch {
                await nextStore.close()
                guard generation == token, !isClosing, !isClosed else { return }
                updateTransaction(await coordinator.transactionState())
                previewPlan = nil
                let recoveredConflict = error is EditConflict && (transaction == .idle || transaction == .inTransaction)
                if let conflict = error as? EditConflict { editConflict = conflict; showingConflict = true }
                if (!recoveredConflict && transaction != .inTransaction) || (error as? DatabaseError)?.connectionLost == true { invalidateEditableSnapshot() }
                show(error)
            }
        }
    }

    func rebaseConflict() {
        guard canEditValues, !hasActiveCellEditor, let conflict = editConflict, let fresh = conflict.freshRow,
              let drafts = draftStore, let context = editContext, let table = editableTable else { return }
        let oldStore = store, count = rowCount, token = UUID()
        let projection = editProjection
        let nextStore = Self.makeStore(allowsSpooling: allowsSpooling)
        generation = token; isBusy = true; isCancelling = false; error = nil
        operation = Task {
            defer { if generation == token { isBusy = false; isCancelling = false; operation = nil } }
            do {
                try await Self.copyEditingResult(from: oldStore, into: nextStore, count: count, replacements: [conflict.row.id: fresh], table: table, projection: projection)
                try Task.checkCancellation()
                guard generation == token, context == editContext, !isClosing, !isClosed else { await nextStore.close(); return }
                try await drafts.rebase(rowIndex: conflict.row.id, onto: fresh)
                guard generation == token, context == editContext, !isClosing, !isClosed else { await nextStore.close(); return }
                // Rebase the fetched baseline too: a draft equal to the fresh
                // value disappears, and its next edit still needs the new xmin.
                store = nextStore; revision &+= 1
                await oldStore.close()
                await publishDrafts(drafts); showingConflict = false
                editExpressionsNeedRefresh = projection?.hasExpressions == true
                status = "Rebased — preview changes again"
            } catch {
                await nextStore.close()
                if generation == token, !isClosing, !isClosed { show(error) }
            }
        }
    }

    private nonisolated static func copyEditingResult(from original: ResultStore, into destination: ResultStore,
                                                     count: Int, replacements: [Int: EditableRowSnapshot], table: EditableTable,
                                                     projection: ResultEditProjection?, insertedRowIDs: Set<Int> = []) async throws {
        try await destination.reset()
        var updatedKeys: [[DatabaseValue]: EditableRowSnapshot] = [:]
        if let projection {
            for (index, replacement) in replacements where !insertedRowIDs.contains(index) {
                guard let row = try await original.rows(in: index..<(index + 1)).first else { throw DatabaseError("The original result is unavailable.") }
                updatedKeys[try projection.primaryKey(in: row, table: table)] = replacement
            }
        }
        for index in 0..<count {
            try Task.checkCancellation()
            guard let originalRow = try await original.rows(in: index..<(index + 1)).first else { throw DatabaseError("The original result is unavailable.") }
            let values: DatabaseRow
            if let projection {
                // A set-returning expression can repeat a base row. Refresh all
                // appearances of the affected key while retaining result aliases.
                if let replacement = updatedKeys[try projection.primaryKey(in: originalRow, table: table)] {
                    values = try projection.projectedRow(applying: replacement, to: originalRow)
                } else { values = originalRow }
            } else if let replacement = replacements[index] {
                values = replacement.values + [.text(replacement.version)]
            } else {
                values = originalRow
            }
            try await destination.append(RowBatch(rows: [values]))
        }
        for index in insertedRowIDs.sorted() {
            try Task.checkCancellation()
            guard let inserted = replacements[index], inserted.values.count == table.columns.count else {
                throw DatabaseError("The inserted row was not returned completely. The insert batch was rolled back.")
            }
            var values: DatabaseRow
            if let projection {
                values = try projection.resultToTable.map { column in
                    guard let column else { throw DatabaseError("New rows require a complete table result without calculated expressions.") }
                    return inserted.values[column]
                }
                if projection.hasHiddenVersion { values.append(.text(inserted.version)) }
            } else { values = inserted.values + [.text(inserted.version)] }
            try await destination.append(RowBatch(rows: [values]))
        }
    }
}
