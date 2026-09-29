import Foundation
import XCTest
import DB3Core
import DB3Postgres
@testable import DB3Workbench

@MainActor
final class WorksheetEditingIntegrationTests: XCTestCase {
    func testInlineDraftPreviewManualApplyCommitAndHiddenVersionExport() async throws {
        try await withTable { sheet, observer, name in
            XCTAssertEqual(sheet.commitMode, .manual)
            XCTAssertEqual(sheet.transaction, .inTransaction)
            XCTAssertTrue(sheet.editBaselineValid)
            XCTAssertEqual(sheet.columns.map(\.name), ["id", "title", "amount", "enabled", "owner_id"])
            let cell = try await sheet.loadCellEditor(row: 0, column: 2)
            XCTAssertEqual(cell.value, .text("1.00"))
            let precise = "123456789012345678901234567890.12345678901234567890"
            try await sheet.stageCell(row: 0, column: 1, value: .text("'; DROP TABLE anything; --"))
            try await sheet.stageCell(row: 0, column: 2, value: .text(precise))
            XCTAssertEqual(sheet.changedCellCount, 2)
            let beforeApply = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(beforeApply, "original")
            sheet.previewChanges()
            try await wait { sheet.previewPlan != nil }
            let plan = try XCTUnwrap(sheet.previewPlan)
            XCTAssertEqual(plan.statements.count, 1)
            XCTAssertFalse(plan.statements[0].sql.contains("DROP TABLE anything"))
            sheet.applyPreview(plan)
            try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertTrue(sheet.draftRows.isEmpty)
            XCTAssertEqual(sheet.status, "Applied — not committed")
            XCTAssertEqual(sheet.transaction, .inTransaction)
            let applied = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(applied[0][2], .text(precise))
            let beforeCommit = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(beforeCommit, "original")

            let export = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
            defer { try? FileManager.default.removeItem(at: export) }
            sheet.exportCSV(to: export)
            try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let csv = try String(contentsOf: export, encoding: .utf8)
            XCTAssertTrue(csv.hasPrefix("\"id\",\"title\",\"amount\",\"enabled\",\"owner_id\"\r\n"))
            XCTAssertFalse(csv.contains("xmin"))

            let store = sheet.store
            sheet.run(sql: "/* explicit review complete */ COMMIT;")
            try await wait { !sheet.isBusy }
            XCTAssertTrue(sheet.store === store)
            XCTAssertEqual(sheet.transaction, .idle)
            XCTAssertFalse(sheet.editBaselineValid)
            let committed = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(committed, "'; DROP TABLE anything; --")
        }
    }

    func testConflictRebaseRollbackAndOwnTransactionForeignKeyLookup() async throws {
        try await withTable { sheet, observer, name in
            try await sheet.stageCell(row: 0, column: 1, value: .text("local draft"))
            _ = try await observer.execute(sql: "UPDATE \(name) SET title = 'other writer' WHERE id = 1") { _ in }
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            sheet.applyPreview(try XCTUnwrap(sheet.previewPlan)); try await wait { !sheet.isBusy }
            XCTAssertTrue(sheet.showingConflict)
            XCTAssertEqual(sheet.editConflict?.freshValues?[1], .text("other writer"))
            XCTAssertEqual(sheet.draftRows.first?.replacements[1], .text("local draft"))
            XCTAssertEqual(sheet.transaction, .inTransaction)
            sheet.error = nil
            sheet.rebaseConflict(); try await wait { !sheet.showingConflict }
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            sheet.applyPreview(try XCTUnwrap(sheet.previewPlan)); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.status, "Applied — not committed")

            let table = try XCTUnwrap(sheet.editableTable), foreignKey = try XCTUnwrap(table.foreignKeys.first)
            let coordinator = try XCTUnwrap(sheet.managedSession)
            try await coordinator.withExclusiveOperation { session in
                _ = try await session.execute(sql: "INSERT INTO \(DatabaseObject.quoteIdentifier(foreignKey.targetSchema)).\(DatabaseObject.quoteIdentifier(foreignKey.targetTable)) VALUES (2, 'new local owner')") { _ in }
            }
            sheet.chooseReference(row: 0, column: 4)
            try await wait { sheet.lookup != nil }
            let picker = try XCTUnwrap(sheet.lookup)
            picker.search = "new local"
            try await wait { !picker.busy }
            let candidate = try XCTUnwrap(picker.candidates.first)
            XCTAssertEqual(candidate.key, [.text("2")])
            sheet.stageReference(candidate, from: picker)
            try await wait { sheet.lookup == nil }
            XCTAssertEqual(sheet.draftRows.first?.replacements[4], .text("2"))
            sheet.run(sql: "ROLLBACK")
            XCTAssertFalse(sheet.isBusy, "Unapplied drafts must block whole-transaction rollback until explicitly resolved.")
            XCTAssertEqual(sheet.transaction, .inTransaction)
            sheet.error = nil; sheet.discardGridDrafts(); try await wait { !sheet.isBusy }
            sheet.run(sql: "ROLLBACK"); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.transaction, .idle)
            XCTAssertFalse(sheet.editBaselineValid)
            let survivingExternalUpdate = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(survivingExternalUpdate, "other writer")
        }
    }

    func testDevelopmentAutoConflictCanRebaseAndApplyCommitAfterConfirmedRollback() async throws {
        try await withTable(environment: .development) { sheet, observer, name in
            sheet.run(sql: "ROLLBACK")
            try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.transaction, .idle)
            sheet.setCommitMode(.auto)
            try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.commitMode, .auto)
            sheet.run()
            try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertTrue(sheet.editBaselineValid)
            XCTAssertEqual(sheet.transaction, .idle)

            _ = try await observer.execute(sql: "UPDATE \(name) SET title = 'external development change' WHERE id = 1") { _ in }
            try await sheet.stageCell(row: 0, column: 1, value: .text("reviewed development edit"))
            let pendingClose = WorksheetCloseSnapshot(sheet, preservingDraft: true)
            XCTAssertFalse(pendingClose.isDirty, "SQL autosave does not resolve a database-value draft.")
            XCTAssertEqual(pendingClose.transaction, .idle)
            XCTAssertEqual(pendingClose.pendingGridCells, 1)
            XCTAssertTrue(pendingClose.hasGridDrafts)
            XCTAssertTrue(pendingClose.needsDecision, "A draft requires a close decision even with no open transaction.")

            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let firstPlan = try XCTUnwrap(sheet.previewPlan)
            XCTAssertEqual(firstPlan.mode, .auto)
            sheet.applyPreview(firstPlan); try await wait { !sheet.isBusy }
            XCTAssertTrue(sheet.showingConflict)
            XCTAssertEqual(sheet.transaction, .idle, "The failed Auto batch must be fully rolled back.")
            XCTAssertTrue(sheet.editBaselineValid, "A recovered conflict must remain available for deliberate rebase.")
            XCTAssertEqual(sheet.editConflict?.freshValues?[1], .text("external development change"))
            XCTAssertEqual(sheet.draftRows.first?.replacements[1], .text("reviewed development edit"))
            let afterConflict = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(afterConflict, "external development change")

            sheet.error = nil
            sheet.rebaseConflict(); try await wait { !sheet.showingConflict }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.draftRows.first?.original.values[1], .text("external development change"))
            let afterRebase = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(afterRebase, "external development change", "Rebase itself only changes local draft state.")
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let rebased = try XCTUnwrap(sheet.previewPlan)
            XCTAssertNotEqual(rebased.id, firstPlan.id)
            sheet.applyPreview(rebased); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.status, "Committed — reload to edit")
            XCTAssertEqual(sheet.transaction, .idle)
            XCTAssertTrue(sheet.draftRows.isEmpty)
            XCTAssertFalse(sheet.editBaselineValid)
            let committed = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(committed, "reviewed development edit")
        }
    }

    func testRebaseThatCoalescesDraftRefreshesStoredValuesAndVersionForNextEdit() async throws {
        try await withTable { sheet, observer, name in
            let originalRows = try await sheet.store.rows(in: 0..<1)
            let oldVersion = try XCTUnwrap(originalRows.first?.last)
            let originalRevision = sheet.revision
            try await sheet.stageCell(row: 0, column: 1, value: .text("agreed title"))
            _ = try await observer.execute(sql: "UPDATE \(name) SET title = 'agreed title', amount = 9.75 WHERE id = 1") { _ in }
            let freshVersion = try await scalar("SELECT xmin::text FROM \(name) WHERE id = 1", on: observer)
            XCTAssertNotEqual(oldVersion, .text(freshVersion))

            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            sheet.applyPreview(try XCTUnwrap(sheet.previewPlan)); try await wait { !sheet.isBusy }
            XCTAssertTrue(sheet.showingConflict)
            XCTAssertEqual(sheet.editConflict?.freshRow?.version, freshVersion)
            XCTAssertEqual(sheet.draftRows.first?.replacements[1], .text("agreed title"))
            sheet.error = nil
            sheet.rebaseConflict(); try await wait { !sheet.showingConflict && !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertTrue(sheet.draftRows.isEmpty, "The desired title already matches the refreshed server row.")
            XCTAssertEqual(sheet.changedCellCount, 0)
            XCTAssertTrue(sheet.editBaselineValid)
            XCTAssertGreaterThan(sheet.revision, originalRevision, "Native grid pages must refresh when the rebase replaces stored rows.")

            let refreshed = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(refreshed.first?[1], .text("agreed title"))
            XCTAssertEqual(refreshed.first?[2], .text("9.75"), "Untouched fields must also display the fresh server row.")
            XCTAssertEqual(refreshed.first?.last, .text(freshVersion))
            XCTAssertNil(sheet.gridPresentation(row: 0, column: 1)?.value, "The refreshed title comes from storage after the draft disappears.")
            let nextEditor = try await sheet.loadCellEditor(row: 0, column: 2)
            XCTAssertEqual(nextEditor.value, .text("9.75"))

            try await sheet.stageCell(row: 0, column: 2, value: .text("12.25"))
            XCTAssertEqual(sheet.draftRows.first?.original.version, freshVersion)
            XCTAssertEqual(sheet.draftRows.first?.original.values[2], .text("9.75"))
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let nextPlan = try XCTUnwrap(sheet.previewPlan)
            XCTAssertEqual(nextPlan.statements.first?.row?.original.version, freshVersion)
            sheet.applyPreview(nextPlan); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertFalse(sheet.showingConflict)
            XCTAssertEqual(sheet.status, "Applied — not committed")
            let beforeCommit = try await scalar("SELECT amount::text FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(beforeCommit, "9.75")
            sheet.run(sql: "COMMIT"); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let committed = try await scalar("SELECT amount::text FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(committed, "12.25")
        }
    }

    func testChangingDraftInvalidatesOldPreviewAndRejectsApplyWithoutWriting() async throws {
        try await withTable { sheet, observer, name in
            try await sheet.stageCell(row: 0, column: 1, value: .text("first preview value"))
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let stale = try XCTUnwrap(sheet.previewPlan)
            try await sheet.stageCell(row: 0, column: 1, value: .text("new unreviewed value"))
            XCTAssertNil(sheet.previewPlan)
            sheet.applyPreview(stale)
            XCTAssertFalse(sheet.isBusy)
            XCTAssertTrue(sheet.error?.contains("out of date") == true)
            XCTAssertEqual(sheet.draftRows.first?.replacements[1], .text("new unreviewed value"))
            XCTAssertEqual(sheet.transaction, .inTransaction)
            let unchanged = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(unchanged, "original")
        }
    }

    func testReadOnlyDomainColumnDoesNotPreventEditingAnOrdinaryColumn() async throws {
        try await withTable(withDomain: true) { sheet, observer, name in
            let table = try XCTUnwrap(sheet.editableTable)
            let domain = try XCTUnwrap(table.columns.first { $0.name == "domain_score" })
            XCTAssertNil(table.readOnlyReason)
            XCTAssertNil(domain.kind)
            XCTAssertNotNil(domain.effectiveReadOnlyReason)
            XCTAssertEqual(sheet.columns.last?.name, "domain_score")
            // PostgreSQL reports the base integer OID in result metadata while
            // its relation catalog retains this domain's distinct type OID.
            XCTAssertEqual(sheet.columns.last?.typeOID, 23)
            XCTAssertNotEqual(domain.typeOID, 23)
            do {
                _ = try await sheet.loadCellEditor(row: 0, column: domain.index)
                XCTFail("Unsupported domain values must remain read-only.")
            } catch {
                XCTAssertEqual(error.localizedDescription, domain.effectiveReadOnlyReason)
            }
            try await sheet.stageCell(row: 0, column: 1, value: .text("normal column remains editable"))
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            sheet.applyPreview(try XCTUnwrap(sheet.previewPlan)); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.status, "Applied — not committed")
            let applied = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(applied.first?[domain.index], .text("3"))
            sheet.run(sql: "COMMIT"); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let committed = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(committed, "normal column remains editable")
        }
    }

    func testGenericSelectStarWithCompletePrimaryKeyCanEditAndCommit() async throws {
        try await withTable { sheet, observer, name in
            try await runGeneric("SELECT * FROM \(name) ORDER BY id", sheet: sheet)
            XCTAssertTrue(sheet.canEditValues)
            XCTAssertEqual(sheet.editProjection?.hasHiddenVersion, false)
            XCTAssertEqual(sheet.editProjection?.resultToTable, [0, 1, 2, 3, 4])
            let fetched = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(fetched.first?.count, 5)
            let editor = try await sheet.loadCellEditor(row: 0, column: 1)
            XCTAssertEqual(editor.value, .text("original"))
            try await sheet.stageCell(row: 0, column: 1, value: .text("edited direct SELECT"))
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            sheet.applyPreview(try XCTUnwrap(sheet.previewPlan)); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.status, "Applied — not committed")
            let applied = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(applied.first?.count, 5)
            XCTAssertEqual(applied.first?[1], .text("edited direct SELECT"))
            sheet.run(sql: "COMMIT"); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let committed = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(committed, "edited direct SELECT")
        }
    }

    func testGenericAliasedSubsetRefreshesDuplicateColumnsAndExportsCompleteProjection() async throws {
        try await withTable { sheet, _, name in
            let query = "SELECT amount AS balance, id AS row_key, title AS display, title AS duplicate_title, upper(title) AS calculated FROM \(name) WHERE id = 1"
            try await runGeneric(query, sheet: sheet)
            XCTAssertTrue(sheet.canEditValues)
            XCTAssertEqual(sheet.columns.map(\.name), ["balance", "row_key", "display", "duplicate_title", "calculated"])
            XCTAssertEqual(sheet.editProjection?.resultToTable, [2, 0, 1, 1, nil])
            XCTAssertNotNil(sheet.gridPresentation(row: 0, column: 4)?.readOnlyReason)
            try await sheet.stageCell(row: 0, column: 2, value: .text("updated title"))
            try await sheet.stageCell(row: 0, column: 0, value: .text("55.50"))
            XCTAssertEqual(sheet.changedCellCount, 2, "Duplicate aliases represent one canonical changed value.")
            XCTAssertEqual(sheet.gridPresentation(row: 0, column: 2)?.value, .text("updated title"))
            XCTAssertEqual(sheet.gridPresentation(row: 0, column: 3)?.value, .text("updated title"))
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            sheet.applyPreview(try XCTUnwrap(sheet.previewPlan)); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let applied = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(applied.first, [.text("55.50"), .text("1"), .text("updated title"), .text("updated title"), .text("ORIGINAL")])
            XCTAssertEqual(sheet.columns.map(\.name), ["balance", "row_key", "display", "duplicate_title", "calculated"])
            XCTAssertTrue(sheet.editExpressionsNeedRefresh)
            XCTAssertTrue(sheet.gridPresentation(row: 0, column: 4)?.readOnlyReason?.contains("refresh") == true)

            let export = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
            defer { try? FileManager.default.removeItem(at: export) }
            sheet.exportCSV(to: export); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let csv = try String(contentsOf: export, encoding: .utf8)
            XCTAssertEqual(csv, "\"balance\",\"row_key\",\"display\",\"duplicate_title\",\"calculated\"\r\n\"55.50\",\"1\",\"updated title\",\"updated title\",\"ORIGINAL\"\r\n")
        }
    }

    func testGenericFirstEditRejectsChangedDisplayedValuesUntilQueryIsRerun() async throws {
        try await withTable { sheet, observer, name in
            let query = "SELECT id, title FROM \(name)"
            try await runGeneric(query, sheet: sheet)
            XCTAssertTrue(sheet.canEditValues)
            _ = try await observer.execute(sql: "UPDATE \(name) SET title = 'changed after fetch' WHERE id = 1") { _ in }
            do {
                _ = try await sheet.loadCellEditor(row: 0, column: 1)
                XCTFail("A changed displayed row must not silently acquire a fresh editing baseline.")
            } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
            XCTAssertTrue(sheet.draftRows.isEmpty)
            let stillFetched = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(stillFetched.first?[1], .text("original"))
            XCTAssertEqual(sheet.transaction, .inTransaction, "Failed verification must recover its read savepoint.")
            try await runGeneric(query, sheet: sheet)
            let refreshedEditor = try await sheet.loadCellEditor(row: 0, column: 1)
            XCTAssertEqual(refreshedEditor.value, .text("changed after fetch"))
        }
    }

    func testGenericMissingPrimaryKeyAndAmbiguousSelfJoinRemainReadOnly() async throws {
        try await withTable { sheet, _, name in
            try await runGeneric("SELECT title FROM \(name)", sheet: sheet)
            XCTAssertFalse(sheet.canEditValues)
            XCTAssertNil(sheet.editableTable)
            XCTAssertTrue(sheet.gridPresentation(row: 0, column: 0)?.readOnlyReason?.contains("primary-key") == true)
            try await runGeneric("SELECT a.id, a.title FROM \(name) AS a JOIN \(name) AS b ON b.id = a.id", sheet: sheet)
            XCTAssertFalse(sheet.canEditValues)
            XCTAssertNil(sheet.editableTable)
            XCTAssertTrue(sheet.gridPresentation(row: 0, column: 1)?.readOnlyReason?.contains("Joins") == true)
            XCTAssertEqual(sheet.rowCount, 1, "A successful read-only result must remain available.")
        }
    }

    func testGenericRepeatedPrimaryKeyAllowsOneDraftAndRefreshesAllResultRows() async throws {
        try await withTable { sheet, observer, name in
            try await runGeneric("SELECT id, title, generate_series(1, 2) AS occurrence FROM \(name) ORDER BY occurrence", sheet: sheet)
            XCTAssertTrue(sheet.canEditValues)
            XCTAssertEqual(sheet.rowCount, 2)
            try await sheet.stageCell(row: 0, column: 1, value: .text("one database update"))
            do {
                try await sheet.stageCell(row: 1, column: 1, value: .text("conflicting duplicate draft"))
                XCTFail("Two displayed copies must not generate competing updates for one primary key.")
            } catch { XCTAssertTrue(error.localizedDescription.contains("pending changes")) }
            XCTAssertEqual(sheet.draftRows.count, 1)
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let plan = try XCTUnwrap(sheet.previewPlan)
            XCTAssertEqual(plan.statements.count, 1)
            sheet.applyPreview(plan); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let rows = try await sheet.store.rows(in: 0..<2)
            XCTAssertEqual(rows, [[.text("1"), .text("one database update"), .text("1")], [.text("1"), .text("one database update"), .text("2")]])
            sheet.run(sql: "COMMIT"); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let committed = try await scalar("SELECT title FROM \(name) WHERE id = 1", on: observer)
            XCTAssertEqual(committed, "one database update")
        }
    }

    func testGenericForeignKeyLookupUsesCanonicalColumnFromReorderedProjection() async throws {
        try await withTable { sheet, observer, name in
            let owners = String(name.dropLast("records".count)) + "owners"
            _ = try await observer.execute(sql: "INSERT INTO \(owners) VALUES (2, 'second owner')") { _ in }
            try await runGeneric("SELECT owner_id AS owner, title AS label, id AS row_key FROM \(name)", sheet: sheet)
            XCTAssertEqual(sheet.editProjection?.resultToTable, [4, 1, 0])
            let editor = try await sheet.loadCellEditor(row: 0, column: 0)
            XCTAssertTrue(editor.canChooseReference)
            sheet.chooseReference(row: 0, column: 0)
            try await wait { sheet.lookup != nil }
            let picker = try XCTUnwrap(sheet.lookup)
            picker.search = "second owner"
            try await wait { !picker.busy }
            XCTAssertNil(picker.error)
            let candidate = try XCTUnwrap(picker.candidates.first)
            sheet.stageReference(candidate, from: picker)
            try await wait { sheet.lookup == nil }
            XCTAssertEqual(sheet.draftRows.first?.replacements[4], .text("2"))
            XCTAssertNil(sheet.draftRows.first?.replacements[0], "The displayed FK position is not the canonical primary-key position.")
            XCTAssertEqual(sheet.gridPresentation(row: 0, column: 0)?.value, .text("2"))
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            sheet.applyPreview(try XCTUnwrap(sheet.previewPlan)); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let applied = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(applied.first, [.text("2"), .text("original"), .text("1")])
        }
    }

    func testInsertedDefaultsNullEmptyAndForeignKeyRefreshReturnedRowsBeforeManualCommit() async throws {
        try await withTable(withInsertDefaults: true) { sheet, observer, name in
            XCTAssertEqual(sheet.insertionRow, 1)
            let firstColumn = try await sheet.createInsert(preferredColumn: 0)
            XCTAssertEqual(firstColumn, 1, "Generated identities should focus the first editable field.")
            let untouched = try await sheet.loadCellEditor(row: 1, column: 1)
            XCTAssertTrue(untouched.usesDefault)
            XCTAssertTrue(untouched.canUseDefault)
            XCTAssertNil(sheet.insertRows.first?.values[1])

            sheet.chooseReference(row: 1, column: 4)
            try await wait { sheet.lookup != nil }
            let picker = try XCTUnwrap(sheet.lookup)
            try await wait { !picker.busy }
            XCTAssertNil(picker.error)
            XCTAssertEqual(picker.insertRowID, sheet.insertRows.first?.id)
            let owner = try XCTUnwrap(picker.candidates.first)
            sheet.stageReference(owner, from: picker)
            try await wait { sheet.lookup == nil }
            XCTAssertEqual(sheet.insertRows.first?.values[4], .text("1"))

            _ = try await sheet.createInsert(preferredColumn: 1)
            try await sheet.stageCell(row: 2, column: 1, value: .null)
            let nullEditor = try await sheet.loadCellEditor(row: 2, column: 1)
            XCTAssertFalse(nullEditor.usesDefault)
            XCTAssertEqual(nullEditor.value, .null)
            _ = try await sheet.createInsert(preferredColumn: 1)
            try await sheet.stageCell(row: 3, column: 1, value: .text(""))
            let emptyEditor = try await sheet.loadCellEditor(row: 3, column: 1)
            XCTAssertFalse(emptyEditor.usesDefault)
            XCTAssertEqual(emptyEditor.value, .text(""))

            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let plan = try XCTUnwrap(sheet.previewPlan)
            XCTAssertEqual(plan.statements.count, 3)
            XCTAssertTrue(plan.statements.allSatisfy(\.isInsert))
            XCTAssertNil(plan.statements[0].insertedRow?.values[1])
            XCTAssertEqual(plan.statements[1].insertedRow?.values[1], .null)
            XCTAssertEqual(plan.statements[2].insertedRow?.values[1], .text(""))
            sheet.applyPreview(plan); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertTrue(sheet.insertRows.isEmpty)
            XCTAssertEqual(sheet.rowCount, 4)
            XCTAssertEqual(sheet.insertionRow, 4)
            XCTAssertEqual(sheet.status, "Applied — not committed")
            let rows = try await sheet.store.rows(in: 1..<4)
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(rows.map { $0[0] }, [.text("10"), .text("11"), .text("12")])
            XCTAssertEqual(rows.map { $0[1] }, [.text("default title"), .null, .text("")])
            XCTAssertEqual(rows[0][2], .text("4.25"))
            XCTAssertEqual(rows[0][3], .text("t"))
            XCTAssertEqual(rows[0][4], .text("1"))
            XCTAssertTrue(rows.allSatisfy { $0.count == 6 && UInt32($0[5].displayText) != nil })
            let beforeCommit = try await scalar("SELECT count(*)::text FROM \(name)", on: observer)
            XCTAssertEqual(beforeCommit, "1", "Apply must keep inserted rows private until explicit Manual commit.")
            sheet.run(sql: "COMMIT"); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            let afterCommit = try await scalar("SELECT count(*)::text FROM \(name)", on: observer)
            XCTAssertEqual(afterCommit, "4")
        }
    }

    func testEmptyTableInsertsAtFirstGridRowAndCanBeEditedAgainAfterApply() async throws {
        try await withTable(empty: true) { sheet, observer, name in
            XCTAssertEqual(sheet.rowCount, 0)
            XCTAssertEqual(sheet.insertionRow, 0)
            XCTAssertEqual(sheet.additionalGridRows, 1)
            let firstColumn = try await sheet.createInsert(preferredColumn: 0)
            XCTAssertEqual(firstColumn, 0, "An ordinary primary key must accept a value on a new row.")
            try await sheet.stageCell(row: 0, column: 0, value: .text("20"))
            try await sheet.stageCell(row: 0, column: 1, value: .text("first row"))
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let plan = try XCTUnwrap(sheet.previewPlan)
            XCTAssertEqual(plan.statements.first?.rowIndex, 0)
            XCTAssertEqual(plan.statements.first?.isInsert, true)
            sheet.applyPreview(plan); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.rowCount, 1)
            let rows = try await sheet.store.rows(in: 0..<1)
            XCTAssertEqual(rows.first?[0], .text("20"))
            XCTAssertEqual(rows.first?[1], .text("first row"))
            XCTAssertEqual(rows.first?[2], .null)
            XCTAssertEqual(sheet.insertionRow, 1)
            try await sheet.stageCell(row: 0, column: 1, value: .text("edited inserted row"))
            XCTAssertEqual(sheet.draftRows.first?.original.version, rows.first?.last?.displayText)
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let update = try XCTUnwrap(sheet.previewPlan)
            XCTAssertEqual(update.statements.first?.isInsert, false)
            sheet.applyPreview(update); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            sheet.run(sql: "COMMIT"); try await wait { !sheet.isBusy }
            let committed = try await scalar("SELECT title FROM \(name) WHERE id=20", on: observer)
            XCTAssertEqual(committed, "edited inserted row")
        }
    }

    func testDefaultOnlyInsertRequiresCloseDecisionAndUndoRedoTracksTheRow() async throws {
        try await withTable(environment: .development, withInsertDefaults: true) { sheet, _, _ in
            sheet.run(sql: "ROLLBACK"); try await wait { !sheet.isBusy }
            sheet.setCommitMode(.auto); try await wait { !sheet.isBusy }
            sheet.run(); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            XCTAssertEqual(sheet.transaction, .idle)
            _ = try await sheet.createInsert(preferredColumn: 1)
            XCTAssertEqual(sheet.insertRows.first?.values, [:])
            XCTAssertEqual(sheet.changedCellCount, 1, "An all-default row still contains pending database work.")
            let pending = WorksheetCloseSnapshot(sheet, preservingDraft: true)
            XCTAssertTrue(pending.hasGridDrafts)
            XCTAssertTrue(pending.needsDecision)
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            XCTAssertTrue(sheet.previewPlan?.statements.first?.sql.contains("DEFAULT VALUES") == true)
            sheet.undoGridEdit(); try await wait { sheet.insertRows.isEmpty }
            XCTAssertNil(sheet.previewPlan)
            XCTAssertFalse(sheet.hasPendingGridWork)
            XCTAssertFalse(WorksheetCloseSnapshot(sheet, preservingDraft: true).hasGridDrafts)
            XCTAssertEqual(sheet.insertionRow, 1)
            sheet.undoGridEdit(redo: true); try await wait { sheet.insertRows.count == 1 }
            XCTAssertEqual(sheet.insertRows.first?.values, [:])
            XCTAssertTrue(WorksheetCloseSnapshot(sheet, preservingDraft: true).needsDecision)
        }
    }

    func testDuplicateInsertRollsBackMixedApplyAndPreservesBothDrafts() async throws {
        try await withTable { sheet, observer, name in
            let originalStore = sheet.store
            try await sheet.stageCell(row: 0, column: 1, value: .text("must roll back"))
            _ = try await sheet.createInsert(preferredColumn: 0)
            try await sheet.stageCell(row: 1, column: 0, value: .text("1"))
            try await sheet.stageCell(row: 1, column: 1, value: .text("duplicate key"))
            sheet.previewChanges(); try await wait { sheet.previewPlan != nil }
            let plan = try XCTUnwrap(sheet.previewPlan)
            XCTAssertEqual(plan.statements.map(\.isInsert), [false, true])
            sheet.applyPreview(plan); try await wait { !sheet.isBusy }
            XCTAssertTrue(sheet.error?.contains("duplicate key") == true)
            XCTAssertEqual(sheet.transaction, .inTransaction)
            XCTAssertTrue(sheet.editBaselineValid)
            XCTAssertTrue(sheet.store === originalStore)
            XCTAssertEqual(sheet.rowCount, 1)
            XCTAssertEqual(sheet.draftRows.first?.replacements[1], .text("must roll back"))
            XCTAssertEqual(sheet.insertRows.first?.values[0], .text("1"))
            let coordinator = try XCTUnwrap(sheet.managedSession)
            let ownValue = try await coordinator.withExclusiveOperation { session in
                let values = EditingTestRows()
                _ = try await session.execute(sql: "SELECT title FROM \(name) WHERE id=1") { await values.receive($0) }
                return await values.first
            }
            XCTAssertEqual(ownValue, "original", "The earlier UPDATE must roll back with the failed INSERT.")
            let outside = try await scalar("SELECT title FROM \(name) WHERE id=1", on: observer)
            XCTAssertEqual(outside, "original")
        }
    }

    private func runGeneric(_ sql: String, sheet: Worksheet) async throws {
        sheet.sql = sql; sheet.selection = NSRange(location: 0, length: 0)
        sheet.run(); try await wait { !sheet.isBusy }
        XCTAssertNil(sheet.error)
        if let error = sheet.error { throw DatabaseError(error) }
    }

    private func withTable(environment: ConnectionEnvironment = .unknown,
                           withDomain: Bool = false,
                           empty: Bool = false,
                           withInsertDefaults: Bool = false,
                           _ body: @MainActor (Worksheet, PostgresSession, String) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DB3_TEST_PORT"].flatMap(Int.init) else { throw XCTSkip("Requires disposable PostgreSQL fixture") }
        let profile = ConnectionProfile(name: "Disposable editing fixture", host: "127.0.0.1", port: port,
            database: env["DB3_TEST_DATABASE"] ?? "postgres", username: env["DB3_TEST_USER"] ?? NSUserName(), tls: .disable, environment: environment)
        let observer = PostgresSession(), schema = "edit_app_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        _ = try await observer.connect(profile: profile, password: "")
        let sheet = Worksheet()
        do {
            let key = withInsertDefaults ? "integer GENERATED BY DEFAULT AS IDENTITY (START WITH 10) PRIMARY KEY" : "integer PRIMARY KEY"
            let title = withInsertDefaults ? "text DEFAULT 'default title'" : "text"
            let amount = withInsertDefaults ? "numeric DEFAULT 4.25" : "numeric"
            let enabled = withInsertDefaults ? "boolean DEFAULT true" : "boolean"
            var statements = ["CREATE SCHEMA \(schema)", "CREATE TABLE \(schema).owners (id integer PRIMARY KEY, name text)",
                        "INSERT INTO \(schema).owners VALUES (1, 'original owner')",
                        "CREATE TABLE \(schema).records (id \(key), title \(title), amount \(amount), enabled \(enabled), owner_id integer REFERENCES \(schema).owners(id))"]
            if !empty { statements.append("INSERT INTO \(schema).records VALUES (1, 'original', 1.00, false, 1)") }
            if withDomain {
                statements += ["CREATE DOMAIN \(schema).nonnegative_integer AS integer CHECK (VALUE >= 0)",
                               "ALTER TABLE \(schema).records ADD COLUMN domain_score \(schema).nonnegative_integer DEFAULT 3"]
            }
            for sql in statements {
                _ = try await observer.execute(sql: sql) { _ in }
            }
            let relationOID = try await scalar("SELECT '\(schema).records'::regclass::oid::text", on: observer)
            let oid = try XCTUnwrap(UInt32(relationOID))
            let target = WorksheetEditTarget(relationOID: oid, schema: schema, name: "records")
            sheet.editTarget = target; sheet.ownedEditSQL = target.initialSQL; sheet.setGeneratedSQL(target.initialSQL)
            sheet.connect(profile, password: "")
            try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            sheet.run(); try await wait { !sheet.isBusy }
            XCTAssertNil(sheet.error)
            guard sheet.editBaselineValid else { throw DatabaseError(sheet.error ?? "Editing snapshot did not load") }
            try await body(sheet, observer, "\(schema).records")
        } catch {
            await sheet.close()
            _ = try? await observer.execute(sql: "DROP SCHEMA IF EXISTS \(schema) CASCADE") { _ in }
            await observer.disconnect()
            throw error
        }
        await sheet.close()
        _ = try await observer.execute(sql: "DROP SCHEMA \(schema) CASCADE") { _ in }
        await observer.disconnect()
    }
    private func scalar(_ sql: String, on session: PostgresSession) async throws -> String {
        let rows = EditingTestRows()
        _ = try await session.execute(sql: sql) { event in await rows.receive(event) }
        let first = await rows.first
        return try XCTUnwrap(first)
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { throw DatabaseError("Editing test timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor EditingTestRows {
    var first: String?
    func receive(_ event: QueryEvent) {
        if case .rows(let batch) = event, first == nil { first = batch.rows.first?.first?.displayText }
    }
}
