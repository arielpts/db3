import Foundation
import XCTest
import DB3Core
@testable import DB3Workbench

/// Uses synthetic sessions and real Worksheet operations. No windows, Keychain,
/// saved connection settings, or live databases participate in these tests.
@MainActor
final class WorksheetTransactionTests: XCTestCase {
    func testNewConnectionIsManualAndFirstSelectOpensOneReusableTransaction() async throws {
        let fixture = try await connected(.production)
        let sheet = fixture.model.active
        XCTAssertEqual(sheet.commitMode, .manual)
        XCTAssertEqual(sheet.transaction, .idle)
        XCTAssertNil(sheet.transactionStartedAt)
        var commands = await fixture.sessions[0].commands
        XCTAssertTrue(commands.isEmpty, "Connecting must not issue BEGIN.")
        try await run("SELECT 'first';", in: sheet)
        let started = sheet.transactionStartedAt
        XCTAssertNotNil(started)
        XCTAssertEqual(sheet.transaction, .inTransaction)
        try await run("SELECT 'second';", in: sheet)
        commands = await fixture.sessions[0].commands
        XCTAssertEqual(commands, ["BEGIN", "SELECT 'first';", "SELECT 'second';"])
        XCTAssertEqual(sheet.transactionStartedAt, started)
        await fixture.model.shutdown()
    }

    func testExplicitCommitAndRollbackPreserveFetchedGrid() async throws {
        let fixture = try await connected(.production)
        let sheet = fixture.model.active
        try await run("SELECT 'visible result';", in: sheet)
        let originalStore = sheet.store, columns = sheet.columns, revision = sheet.revision
        let rows = try await sheet.store.rows(in: 0..<sheet.rowCount)
        for command in ["COMMIT", "BEGIN", "ROLLBACK"] {
            sheet.run(sql: command)
            try await settled(sheet)
            XCTAssertNil(sheet.error, command)
            XCTAssertTrue(sheet.store === originalStore, command)
            XCTAssertEqual(sheet.columns, columns, command)
            XCTAssertEqual(sheet.revision, revision, command)
            let currentRows = try await sheet.store.rows(in: 0..<sheet.rowCount)
            XCTAssertEqual(currentRows, rows, command)
        }
        XCTAssertEqual(sheet.transaction, .idle)
        XCTAssertNil(sheet.transactionStartedAt)
        await fixture.model.shutdown()
    }

    func testFailedTransactionBlocksOrdinaryRunAndCommitAsRollbackRefreshesState() async throws {
        let fixture = try await connected(.unknown)
        let sheet = fixture.model.active
        await fixture.sessions[0].failExecution(of: "SELECT broken;", with: DatabaseError("synthetic server failure", sqlState: "42601"))
        try await run("SELECT broken;", in: sheet)
        XCTAssertEqual(sheet.transaction, .failed)
        let failedStore = sheet.store, failedRevision = sheet.revision
        try await run("SELECT 'blocked';", in: sheet)
        XCTAssertTrue(sheet.error?.contains("Roll back") == true)
        XCTAssertTrue(sheet.store === failedStore)
        XCTAssertEqual(sheet.revision, failedRevision)
        sheet.run(sql: "COMMIT")
        try await settled(sheet)
        XCTAssertTrue(sheet.error?.contains("rolled back") == true)
        XCTAssertEqual(sheet.transaction, .idle, "A failed COMMIT ending as ROLLBACK must refresh backend state even with no new result store.")
        XCTAssertNil(sheet.transactionStartedAt)
        let commands = await fixture.sessions[0].commands
        XCTAssertEqual(commands, ["BEGIN", "SELECT broken;", "COMMIT"])
        await fixture.model.shutdown()
    }

    func testDeferredConstraintCommitFailureRefreshesBackendStateWithoutReplacingGrid() async throws {
        let fixture = try await connected(.production)
        let sheet = fixture.model.active
        try await run("SELECT 'previous result';", in: sheet)
        let previous = sheet.store
        await fixture.sessions[0].failExecution(of: "COMMIT", with: DatabaseError("synthetic deferred constraint", sqlState: "23503"), state: .idle)
        sheet.run(sql: "COMMIT")
        try await settled(sheet)
        XCTAssertEqual(sheet.transaction, .idle)
        XCTAssertTrue(sheet.error?.contains("deferred constraint") == true)
        XCTAssertTrue(sheet.store === previous)
        XCTAssertEqual(sheet.rowCount, 1)
        await fixture.model.shutdown()
    }

    func testProductionAndUnknownRejectStaleAutoModeRequestsWithoutSendingSQL() async throws {
        for environment in [ConnectionEnvironment.production, .unknown] {
            let fixture = try await connected(environment)
            let sheet = fixture.model.active
            sheet.setCommitMode(.auto)
            try await settled(sheet)
            XCTAssertEqual(sheet.commitMode, .manual)
            XCTAssertTrue(sheet.error?.contains("Development") == true)
            // Simulates a stale stored/menu choice bypassing the normal UI setter.
            sheet.commitMode = .auto
            try await run("UPDATE synthetic SET value = 2;", in: sheet)
            let commands = await fixture.sessions[0].commands
            XCTAssertTrue(commands.isEmpty)
            XCTAssertTrue(sheet.error?.contains("Development") == true)
            await fixture.model.shutdown()
        }
    }

    func testDevelopmentOptInDoesNotCommitAndReconnectResetsManual() async throws {
        let fixture = try await connected(.development)
        let sheet = fixture.model.active
        sheet.setCommitMode(.auto)
        try await settled(sheet)
        XCTAssertEqual(sheet.commitMode, .auto)
        try await run("SELECT 'auto';", in: sheet)
        XCTAssertEqual(sheet.transaction, .idle)
        sheet.run(sql: "BEGIN")
        try await settled(sheet)
        sheet.setCommitMode(.manual)
        try await settled(sheet)
        XCTAssertEqual(sheet.commitMode, .auto, "Mode change cannot resolve an open transaction implicitly.")
        XCTAssertTrue(sheet.error?.contains("Commit or roll back") == true)
        sheet.run(sql: "ROLLBACK")
        try await settled(sheet)
        let profile = try XCTUnwrap(sheet.profile)
        sheet.connect(profile, password: "synthetic")
        try await settled(sheet)
        XCTAssertEqual(sheet.commitMode, .manual)
        XCTAssertEqual(sheet.transaction, .idle)
        XCTAssertNil(sheet.transactionStartedAt)
        let commands = await fixture.sessions[0].commands
        XCTAssertEqual(commands, ["SELECT 'auto';", "BEGIN", "ROLLBACK"])
        await fixture.model.shutdown()
    }

    func testConnectedEnvironmentIsImmutableUntilReconnect() async throws {
        let fixture = try await connected(.production)
        let sheet = fixture.model.active
        sheet.profile?.environment = .development
        XCTAssertEqual(sheet.environment, .production)
        sheet.setCommitMode(.auto)
        try await settled(sheet)
        XCTAssertEqual(sheet.commitMode, .manual)
        let commands = await fixture.sessions[0].commands
        XCTAssertTrue(commands.isEmpty)
        await fixture.model.shutdown()
    }

    func testSavedProfileTighteningImmediatelyDisablesAutoUntilReconnect() async throws {
        let fixture = try await connected(.development)
        let sheet = fixture.model.active
        var profile = try XCTUnwrap(sheet.profile)
        fixture.model.profiles = [profile]
        sheet.setCommitMode(.auto)
        try await settled(sheet)
        XCTAssertEqual(sheet.commitMode, .auto)
        profile.environment = .production
        fixture.model.profiles = [profile]
        XCTAssertEqual(sheet.commitMode, .manual, "Saved production policy must apply synchronously.")
        XCTAssertEqual(sheet.environment, .production)
        let owner = try XCTUnwrap(sheet.managedSession)
        XCTAssertThrowsError(try owner.authorizeAutoCommit())
        profile.environment = .development
        fixture.model.profiles = [profile]
        sheet.setCommitMode(.auto)
        try await settled(sheet)
        XCTAssertEqual(sheet.commitMode, .manual, "A later profile edit cannot loosen the live owner's stricter policy.")
        XCTAssertEqual(sheet.environment, .production)
        let commands = await fixture.sessions[0].commands
        XCTAssertTrue(commands.isEmpty)
        await fixture.model.shutdown()
    }

    func testProfileTighteningDuringAuthenticationSurvivesNewOwnerCreation() async throws {
        let fixture = WorkbenchFixture(), profile = ConnectionProfile(name: "Connecting", environment: .development)
        let sheet = fixture.model.active
        fixture.model.profiles = [profile]
        await fixture.sessions[0].suspendConnect()
        sheet.connect(profile, password: "synthetic")
        for _ in 0..<200 {
            if await fixture.sessions[0].connections.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(sheet.isBusy)
        fixture.model.profiles[0].environment = .production
        await fixture.sessions[0].finishConnect()
        try await settled(sheet)
        XCTAssertTrue(sheet.isConnected)
        XCTAssertEqual(sheet.environment, .production, "A stale captured Development profile cannot replace a policy tightened during authentication.")
        sheet.setCommitMode(.auto)
        try await settled(sheet)
        XCTAssertEqual(sheet.commitMode, .manual)
        let commands = await fixture.sessions[0].commands
        XCTAssertTrue(commands.isEmpty)
        await fixture.model.shutdown()
    }

    func testUnknownCommitOutcomePreservesGridAndDisconnectsWithoutReplay() async throws {
        let fixture = try await connected(.production)
        let sheet = fixture.model.active
        try await run("SELECT 'keep for comparison';", in: sheet)
        let store = sheet.store
        await fixture.sessions[0].failExecution(of: "COMMIT", with: DatabaseError("synthetic connection lost", connectionLost: true), state: .unknown)
        sheet.run(sql: "COMMIT")
        try await settled(sheet)
        XCTAssertFalse(sheet.isConnected)
        XCTAssertEqual(sheet.transaction, .unknown)
        XCTAssertTrue(sheet.error?.localizedCaseInsensitiveContains("outcome is unknown") == true)
        XCTAssertTrue(sheet.store === store)
        XCTAssertEqual(sheet.rowCount, 1)
        XCTAssertFalse(sheet.editBaselineValid)
        let commands = await fixture.sessions[0].commands
        XCTAssertEqual(commands, ["BEGIN", "SELECT 'keep for comparison';", "COMMIT"])
        await fixture.model.shutdown()
    }

    func testActiveCellEditorPreventsRunModeChangeAndConnectionReplacement() async throws {
        let fixture = try await connected(.development)
        let sheet = fixture.model.active
        let profile = sheet.profile
        sheet.hasActiveCellEditor = true
        sheet.run(sql: "COMMIT")
        sheet.setCommitMode(.auto)
        sheet.disconnect()
        sheet.connect(ConnectionProfile(name: "Other", environment: .development), password: "synthetic")
        XCTAssertFalse(sheet.isBusy)
        XCTAssertTrue(sheet.isConnected)
        XCTAssertEqual(sheet.profile, profile)
        XCTAssertEqual(sheet.commitMode, .manual)
        XCTAssertNil(sheet.beginConnectionIntent())
        let commands = await fixture.sessions[0].commands
        XCTAssertTrue(commands.isEmpty)
        sheet.hasActiveCellEditor = false
        await fixture.model.shutdown()
    }

    func testRecoveryPreservesEnvironmentButNeverRestoresAutoOrTransactionState() throws {
        let original = Worksheet(sessionFactory: { _ in RecordingDatabaseSession() })
        original.profile = ConnectionProfile(environment: .production)
        original.commitMode = .auto
        original.transaction = .inTransaction
        let bytes = try JSONEncoder().encode(original.workspaceSnapshot())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(json["commitMode"])
        XCTAssertNil(json["transaction"])
        let restored = Worksheet(sessionFactory: { _ in RecordingDatabaseSession() })
        restored.restoreWorkspace(try JSONDecoder().decode(WorkspaceTabSnapshot.self, from: bytes))
        XCTAssertEqual(restored.profile?.environment, .production)
        XCTAssertEqual(restored.commitMode, .manual)
        XCTAssertEqual(restored.transaction, .unknown)
        XCTAssertFalse(restored.isConnected)
    }

    func testGridDraftWarnsOnQuitAndDoesNotLeakIntoSQLRecovery() async throws {
        let fixture = try await connected(.development)
        let sheet = fixture.model.active
        let table = EditableTable(relationOID: 42, schema: "public", name: "synthetic", columns: [
            EditableColumn(index: 0, attributeNumber: 1, name: "id", typeOID: 23, typeSQL: "integer", nullable: false, kind: .integer, readOnlyReason: "Primary key"),
            EditableColumn(index: 1, attributeNumber: 2, name: "title", typeOID: 25, typeSQL: "text", nullable: true, kind: .text)
        ], primaryKeyAttributes: [1], metadataRevision: "fixture")
        let context = EditSourceContext(sessionID: UUID(), resultRevision: UUID(), transactionEpoch: 0, relationOID: 42, metadataRevision: "fixture")
        let drafts = EditDraftStore(context: context, table: table)
        try await drafts.stage(row: EditableRowSnapshot(rowIndex: 0, values: [.text("1"), .text("original")], version: "1"),
                               columnIndex: 1, value: .text("private-memory-only-draft"))
        sheet.draftStore = drafts
        await sheet.publishDrafts(drafts)
        sheet.run(sql: "COMMIT")
        XCTAssertFalse(sheet.isBusy)
        let commands = await fixture.sessions[0].commands
        XCTAssertTrue(commands.isEmpty)
        let recovery = try JSONEncoder().encode(sheet.workspaceSnapshot())
        XCTAssertFalse(String(decoding: recovery, as: UTF8.self).contains("private-memory-only-draft"))
        fixture.dialogs.closeDecisions = [.keepOpen]
        let closed = await fixture.model.requestCloseWorkspace()
        XCTAssertFalse(closed)
        XCTAssertFalse(sheet.isClosed)
        XCTAssertEqual(fixture.dialogs.snapshots.first?.pendingGridCells, 1)
        XCTAssertEqual(sheet.changedCellCount, 1)
        await fixture.model.shutdown()
    }

    private func connected(_ environment: ConnectionEnvironment) async throws -> WorkbenchFixture {
        let fixture = WorkbenchFixture()
        fixture.model.active.connect(ConnectionProfile(name: "Synthetic", environment: environment), password: "synthetic")
        try await settled(fixture.model.active)
        XCTAssertTrue(fixture.model.active.isConnected)
        return fixture
    }

    private func run(_ sql: String, in sheet: Worksheet) async throws {
        sheet.sql = sql; sheet.selection = NSRange(location: 0, length: 0)
        sheet.run()
        try await settled(sheet)
    }

    private func settled(_ sheet: Worksheet) async throws {
        for _ in 0..<400 {
            if !sheet.isBusy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DatabaseError("Timed out waiting for synthetic worksheet transaction work")
    }
}
