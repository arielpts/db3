import Foundation
import XCTest
import DB3Core
@testable import DB3Workbench

/// The fake owns explicit gates at SAVEPOINT and recovery. Assertions run while
/// those gates are held, so cancellation races do not depend on a slow server,
/// GUI events, or sleep durations beyond the picker's normal search debounce.
@MainActor
final class ForeignKeyLookupCancellationTests: XCTestCase {
    func testDiscardWaitsForCancelledLookupRecoveryBeforeReleasingWorksheet() async throws {
        let (sheet, session) = try await fixture()
        sheet.chooseReference(row: 0, column: 1)
        try await wait { await session.phase == .savepoint }
        let picker = try XCTUnwrap(sheet.lookup)
        let originalStore = sheet.store
        XCTAssertEqual(sheet.changedCellCount, 1)

        sheet.discardGridDrafts()
        XCTAssertTrue(sheet.isBusy)
        XCTAssertTrue(sheet.lookup === picker)
        XCTAssertEqual(sheet.changedCellCount, 1, "Drafts remain until cancellation has drained the lookup.")
        sheet.run(sql: "COMMIT")
        XCTAssertTrue(sheet.isBusy)
        await session.finishSavepoint()
        try await wait { await session.phase == .recovery }
        XCTAssertTrue(sheet.isBusy, "Rollback-to-savepoint is still in progress.")
        XCTAssertEqual(sheet.changedCellCount, 1)
        do {
            try await sheet.managedSession?.withExclusiveOperation { _ in () }
            XCTFail("The operation lease must remain held through recovery.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("operation in progress")) }

        await session.finishRecovery()
        try await wait { !sheet.isBusy }
        XCTAssertNil(sheet.lookup)
        XCTAssertEqual(sheet.changedCellCount, 0)
        XCTAssertTrue(sheet.draftRows.isEmpty)
        XCTAssertTrue(sheet.editBaselineValid)
        XCTAssertTrue(sheet.isConnected)
        XCTAssertNil(sheet.error)
        XCTAssertTrue(sheet.store === originalStore)
        let commands = await session.commandKinds
        XCTAssertEqual(commands, [.savepoint, .rollbackToSavepoint, .releaseSavepoint])
        try await sheet.managedSession?.withExclusiveOperation { _ in () }
        await sheet.close()
    }

    func testClosedPickerStillReportsFatalRecoveryAndInvalidatesEditableSource() async throws {
        let (sheet, session) = try await fixture()
        sheet.chooseReference(row: 0, column: 1)
        try await wait { await session.phase == .savepoint }
        let picker = try XCTUnwrap(sheet.lookup)
        sheet.closeLookup()
        XCTAssertTrue(sheet.lookup === picker, "The owner retains the canceled picker until its work settles.")
        await session.finishSavepoint()
        try await wait { await session.phase == .recovery }
        await session.finishRecovery(failing: true)
        await picker.waitUntilIdle()
        try await wait { sheet.lookup == nil }

        XCTAssertFalse(sheet.isConnected)
        XCTAssertEqual(sheet.transaction, .unknown)
        XCTAssertFalse(sheet.editBaselineValid)
        XCTAssertTrue(sheet.error?.contains("recovery failed") == true)
        XCTAssertEqual(sheet.changedCellCount, 1, "Closing a lookup does not discard the user's unverified draft.")
        let commands = await session.commandKinds
        XCTAssertEqual(commands, [.savepoint, .rollbackToSavepoint])
        await sheet.close()
    }

    func testSupersededSearchStillReportsFatalRecoveryAndNeverStartsAnotherLookup() async throws {
        let (sheet, session) = try await fixture()
        sheet.chooseReference(row: 0, column: 1)
        try await wait { await session.phase == .savepoint }
        let picker = try XCTUnwrap(sheet.lookup)
        picker.search = "new search"
        await session.finishSavepoint()
        try await wait { await session.phase == .recovery }
        await session.finishRecovery(failing: true)
        await picker.waitUntilIdle()

        XCTAssertNil(sheet.lookup)
        XCTAssertFalse(sheet.isConnected)
        XCTAssertFalse(sheet.editBaselineValid)
        XCTAssertTrue(sheet.error?.contains("recovery failed") == true)
        let commands = await session.commandKinds
        XCTAssertEqual(commands, [.savepoint, .rollbackToSavepoint], "The replacement search cannot reuse a session whose recovery failed.")
        await sheet.close()
    }

    func testSecondChooserCannotReplacePickerWhileItOwnsSession() async throws {
        let (sheet, session) = try await fixture()
        sheet.chooseReference(row: 0, column: 1)
        try await wait { await session.phase == .savepoint }
        let first = try XCTUnwrap(sheet.lookup)
        sheet.chooseReference(row: 0, column: 1)
        // The rejected action must not schedule an asynchronous replacement.
        await Task.yield()
        XCTAssertTrue(sheet.lookup === first)
        sheet.discardGridDrafts()
        await session.finishSavepoint()
        try await wait { await session.phase == .recovery }
        XCTAssertTrue(sheet.isBusy)
        await session.finishRecovery()
        try await wait { !sheet.isBusy }
        XCTAssertNil(sheet.lookup)
        let commands = await session.commandKinds
        XCTAssertEqual(commands, [.savepoint, .rollbackToSavepoint, .releaseSavepoint])
        await sheet.close()
    }

    private func fixture() async throws -> (Worksheet, LookupRecoverySession) {
        let session = LookupRecoverySession()
        let sheet = Worksheet(sessionFactory: { _ in session })
        let key = EditableColumn(index: 0, attributeNumber: 1, name: "id", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: false, kind: .integer, readOnlyReason: "Primary key")
        let owner = EditableColumn(index: 1, attributeNumber: 2, name: "owner_id", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: true, kind: .integer)
        let referenced = EditableColumn(index: 0, attributeNumber: 1, name: "id", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: false, kind: .integer)
        let fk = EditableForeignKey(id: 20, name: "owner", localAttributes: [2], targetRelationOID: 30,
                                    targetSchema: "public", targetTable: "owners", targetColumns: [referenced])
        let table = EditableTable(relationOID: 10, schema: "public", name: "records", columns: [key, owner],
                                  primaryKeyAttributes: [1], foreignKeys: [fk], metadataRevision: "fixture")
        let context = EditSourceContext(sessionID: UUID(), resultRevision: UUID(), transactionEpoch: 1,
                                       relationOID: table.relationOID, metadataRevision: table.metadataRevision)
        sheet.isConnected = true; sheet.transaction = .inTransaction
        sheet.managedSession = ManagedSession(session: session, environment: .unknown)
        sheet.editableTable = table; sheet.editContext = context; sheet.editBaselineValid = true
        sheet.columns = table.databaseColumns; sheet.rowCount = 1
        try await sheet.store.reset()
        try await sheet.store.append(RowBatch(rows: [[.text("1"), .text("7"), .text("8")]]))
        let drafts = EditDraftStore(context: context, table: table)
        sheet.draftStore = drafts
        try await drafts.stage(row: EditableRowSnapshot(rowIndex: 0, values: [.text("1"), .text("7")], version: "8"),
                               columnIndex: 1, value: .text("9"))
        await sheet.publishDrafts(drafts)
        return (sheet, session)
    }

    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DatabaseError("Timed out waiting for the controlled lookup cancellation gate.")
    }
}

private actor LookupRecoverySession: DatabaseSession {
    enum Phase { case idle, savepoint, recovery, complete }
    private(set) var phase: Phase = .idle
    private(set) var commandKinds: [SQLTransactionControl] = []
    private var state: TransactionState = .inTransaction
    private var savepointGate: CheckedContinuation<Void, Never>?
    private var recoveryGate: CheckedContinuation<Void, Never>?
    private var failRecovery = false

    func connect(profile: ConnectionProfile, password: String) async throws -> SessionInfo { SessionInfo(serverVersion: "fake", backendPID: 0) }
    func transactionState() async -> TransactionState { state }
    func cancel() async { }
    func disconnect() async {
        state = .unknown
        savepointGate?.resume(); savepointGate = nil
        recoveryGate?.resume(); recoveryGate = nil
    }
    func finishSavepoint() { savepointGate?.resume(); savepointGate = nil }
    func finishRecovery(failing: Bool = false) {
        failRecovery = failing
        recoveryGate?.resume(); recoveryGate = nil
    }
    func execute(sql: String, onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        let kind = try SQLTransactionControl.classify(sql)
        commandKinds.append(kind)
        let command: String
        switch kind {
        case .savepoint:
            phase = .savepoint
            await withCheckedContinuation { savepointGate = $0 }
            command = "SAVEPOINT"
        case .rollbackToSavepoint:
            phase = .recovery
            await withCheckedContinuation { recoveryGate = $0 }
            if failRecovery { state = .unknown; throw DatabaseError("Synthetic lookup recovery loss", connectionLost: true) }
            command = "ROLLBACK"
        case .releaseSavepoint: phase = .complete; command = "RELEASE"
        default: throw DatabaseError("Unexpected SQL after lookup was canceled before metadata inspection.")
        }
        return QuerySummary(command: command, rowCount: 0, transaction: state, elapsed: 0)
    }
}
