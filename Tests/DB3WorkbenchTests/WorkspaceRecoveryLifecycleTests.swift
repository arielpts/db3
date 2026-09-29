import Foundation
import XCTest
import DB3Core
@testable import DB3Workbench

@MainActor
final class WorkspaceRecoveryLifecycleTests: XCTestCase {
    func testQuitPreservesDirtyTabsAndRestoresDisconnectedWithoutPromptsOrSQLFileWrites() async throws {
        let recovery = ControllableWorkspaceStore()
        let fixture = RecoveryWorkbenchFixture(recovery: recovery); let model = fixture.model
        let profile = ConnectionProfile(name: "Saved connection", host: "fixture.invalid", database: "fixture")
        model.profiles = [profile]; model.selectedBrowserProfileID = profile.id
        let first = model.active
        let url = URL(fileURLWithPath: "/tmp/db3-recovery-example.sql")
        let token = first.beginLoading(from: url)
        XCTAssertTrue(first.completeLoading("SELECT 'saved';", token: token, revision: first.documentRevision))
        first.title = "Edited file"; first.sql = "SELECT '🐘 unsaved';"
        first.selection = NSRange(location: 8, length: 2)
        first.profile = profile; first.queryContext = QueryOpeningContext(profile: profile, schema: "Sales", object: "Orders")
        model.addWorksheet()
        let second = model.active; second.sql = "SELECT 'untitled draft';"; second.title = "Draft"
        second.allowsSpooling = false
        model.selectTab(first.id); model.showingInspector = true
        let originalFirstSQL = first.sql
        let closed = await model.requestCloseWorkspace()
        XCTAssertTrue(closed)
        XCTAssertTrue(fixture.dialogs.snapshots.isEmpty, "Dirty SQL must not prompt when the whole workspace is preserved.")
        let writes = await fixture.persistence.writes
        XCTAssertTrue(writes.isEmpty, "Recovery must not overwrite the user's SQL file.")
        XCTAssertTrue(first.isClosed); XCTAssertTrue(second.isClosed)
        let persisted = await recovery.snapshot
        let saved = try XCTUnwrap(persisted)
        XCTAssertEqual(saved.tabs.map(\.title), ["Edited file", "Draft"])
        XCTAssertEqual(saved.tabs[0].sql, originalFirstSQL)
        XCTAssertEqual(saved.tabs[0].savedSQL, "SELECT 'saved';")

        let restored = RecoveryWorkbenchFixture(recovery: recovery)
        try await restored.persistence.saveProfiles([profile])
        await restored.model.load()
        let reopened = restored.model.active
        XCTAssertEqual(restored.model.worksheets.count, 2)
        XCTAssertEqual(reopened.sql, originalFirstSQL)
        XCTAssertEqual(reopened.savedSQL, "SELECT 'saved';")
        XCTAssertEqual(reopened.fileURL, url)
        XCTAssertEqual(reopened.selection, NSRange(location: 8, length: 2))
        XCTAssertEqual(reopened.profile, profile)
        XCTAssertEqual(reopened.queryContext?.schema, "Sales")
        XCTAssertTrue(reopened.isDirty)
        XCTAssertFalse(reopened.isConnected)
        XCTAssertTrue(reopened.columns.isEmpty)
        XCTAssertEqual(reopened.transaction, .unknown)
        XCTAssertTrue(restored.model.showingInspector)
        XCTAssertEqual(restored.model.objectBrowser.phase, .notLoaded)
        let passwords = await restored.persistence.passwordReads
        XCTAssertTrue(passwords.isEmpty)
        for session in restored.sessions {
            let connections = await session.connections; let queries = await session.queries
            XCTAssertTrue(connections.isEmpty); XCTAssertTrue(queries.isEmpty)
        }
        let IDs = restored.model.worksheets.map(\.id)
        await restored.model.load()
        XCTAssertEqual(restored.model.worksheets.map(\.id), IDs, "Repeated scene tasks must not restore duplicate tabs.")
        await restored.model.shutdown()
    }

    func testUncommittedAndFailedTransactionsStillWarnAndCancellationKeepsEverythingOpen() async throws {
        for state in [TransactionState.inTransaction, .failed] {
            let recovery = ControllableWorkspaceStore()
            let fixture = RecoveryWorkbenchFixture(recovery: recovery); let model = fixture.model
            let sheet = model.active; sheet.sql = "UPDATE example SET value = 1;"; sheet.transaction = state
            fixture.dialogs.closeDecisions = [.keepOpen]
            let cancelled = await model.requestCloseWorkspace()
            XCTAssertFalse(cancelled)
            XCTAssertFalse(sheet.isClosed)
            XCTAssertEqual(fixture.dialogs.snapshots.first?.transaction, state)
            XCTAssertEqual(fixture.dialogs.snapshots.first?.isDirty, false)
            XCTAssertEqual(fixture.dialogs.snapshots.first?.preservesDraft, true)
            let rejectedSaveCount = await recovery.saveCount
            let rejectedDisconnects = await fixture.sessions[0].disconnectCount
            XCTAssertEqual(rejectedSaveCount, 0); XCTAssertEqual(rejectedDisconnects, 0)
            fixture.dialogs.closeDecisions = [.discard]
            let accepted = await model.requestCloseWorkspace()
            XCTAssertTrue(accepted)
            let snapshot = await recovery.snapshot
            XCTAssertEqual(snapshot?.tabs.first?.sql, "UPDATE example SET value = 1;")
            let queries = await fixture.sessions[0].queries
            XCTAssertFalse(queries.contains("COMMIT"))
        }
    }

    func testFailedRecoveryWritePreventsQuitAndKeepsSQLAndSessionsOpen() async throws {
        let recovery = ControllableWorkspaceStore()
        await recovery.failWrites()
        let fixture = RecoveryWorkbenchFixture(recovery: recovery); let model = fixture.model
        let sheet = model.active; sheet.sql = "SELECT 'keep me';"
        let closed = await model.requestCloseWorkspace()
        XCTAssertFalse(closed)
        XCTAssertTrue(model.active === sheet)
        XCTAssertFalse(sheet.isClosed)
        XCTAssertFalse(sheet.isClosePending)
        XCTAssertTrue(sheet.isDirty)
        XCTAssertEqual(sheet.sql, "SELECT 'keep me';")
        XCTAssertTrue(model.error?.contains("Could not preserve") == true)
        let disconnects = await fixture.sessions[0].disconnectCount
        XCTAssertEqual(disconnects, 0)
        await model.shutdown()
    }

    func testTransactionChangedDuringSnapshotWriteRequiresANewDecision() async throws {
        let recovery = ControllableWorkspaceStore()
        await recovery.holdWrites()
        let fixture = RecoveryWorkbenchFixture(recovery: recovery); let model = fixture.model
        let sheet = model.active
        sheet.sql = "BEGIN;"; sheet.isBusy = true; sheet.transaction = .idle
        fixture.dialogs.closeDecisions = [.discard, .keepOpen]
        let closing = Task { await model.requestCloseWorkspace() }
        for _ in 0..<100 {
            if await recovery.isWriting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let writing = await recovery.isWriting
        XCTAssertTrue(writing)
        sheet.isBusy = false; sheet.transaction = .inTransaction
        await recovery.finishWrites()
        let closed = await closing.value
        XCTAssertFalse(closed)
        XCTAssertEqual(fixture.dialogs.snapshots.count, 2)
        XCTAssertEqual(fixture.dialogs.snapshots.last?.transaction, .inTransaction)
        XCTAssertFalse(sheet.isClosed)
        await model.shutdown()
    }

    func testIndividualDirtyTabCloseStillAsksBeforeDiscardingIt() async {
        let fixture = RecoveryWorkbenchFixture(recovery: ControllableWorkspaceStore())
        let sheet = fixture.model.active; sheet.sql = "SELECT 'draft';"
        fixture.dialogs.closeDecisions = [.keepOpen]
        let closed = await fixture.model.closeTab(id: sheet.id)
        XCTAssertFalse(closed)
        XCTAssertEqual(fixture.dialogs.snapshots.first?.isDirty, true)
        XCTAssertEqual(fixture.dialogs.snapshots.first?.preservesDraft, false)
        await fixture.model.shutdown()
    }

    func testCursorAndTabChangesDuringRecoveryWriteAreSavedAgainBeforeClose() async throws {
        let recovery = ControllableWorkspaceStore()
        await recovery.holdWrites()
        let fixture = RecoveryWorkbenchFixture(recovery: recovery); let model = fixture.model
        let first = model.active; first.sql = "SELECT 'first';"
        model.addWorksheet(); let second = model.active; second.sql = "SELECT 'second';"
        let closing = Task { await model.requestCloseWorkspace() }
        for _ in 0..<100 {
            if await recovery.isWriting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let writing = await recovery.isWriting
        XCTAssertTrue(writing)
        first.selection = NSRange(location: 8, length: 5)
        model.selectTab(first.id); model.moveTab(first.id, by: 1); model.showingInspector = true
        await recovery.finishWrites()
        let closed = await closing.value
        XCTAssertTrue(closed)
        let saved = await recovery.snapshot
        let count = await recovery.saveCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(saved?.selectedTabIndex, 1)
        XCTAssertEqual(saved?.tabs.map(\.sql), ["SELECT 'second';", "SELECT 'first';"])
        XCTAssertEqual(saved?.tabs.last?.selectionLocation, 8)
        XCTAssertEqual(saved?.tabs.last?.selectionLength, 5)
        XCTAssertEqual(saved?.showingInspector, true)
    }

    func testSwitchingConnectionsClearsOldObjectContextBeforeRecovery() async throws {
        let fixture = RecoveryWorkbenchFixture(recovery: ControllableWorkspaceStore())
        let sheet = fixture.model.active
        let old = ConnectionProfile(name: "Old", host: "old.invalid", database: "old_db")
        let new = ConnectionProfile(name: "New", host: "new.invalid", database: "new_db")
        sheet.profile = old
        sheet.queryContext = QueryOpeningContext(profile: old, schema: "OldSchema", object: "OldObject")
        sheet.connect(new, password: "fake")
        for _ in 0..<100 {
            if !sheet.isBusy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = sheet.workspaceSnapshot()
        XCTAssertEqual(snapshot.profile, new)
        XCTAssertEqual(snapshot.database, "new_db")
        XCTAssertNil(snapshot.schema)
        XCTAssertNil(snapshot.object)
        await fixture.model.shutdown()
    }
}

@MainActor
private final class RecoveryWorkbenchFixture {
    let persistence = MemoryWorkbenchPersistence()
    let dialogs = ScriptedWorkbenchDialogs()
    let recovery: any WorkspaceRecoveryPersistence
    var sessions: [RecordingDatabaseSession] = []
    init(recovery: any WorkspaceRecoveryPersistence) { self.recovery = recovery }
    lazy var model = WorkbenchModel(persistence: persistence, dialogs: dialogs, workspaceStore: recovery, worksheetFactory: { [unowned self] title in
        let session = RecordingDatabaseSession(); self.sessions.append(session)
        return Worksheet(title: title, sessionFactory: { _ in session })
    })
}

private actor ControllableWorkspaceStore: WorkspaceRecoveryPersistence {
    private(set) var snapshot: WorkspaceSnapshot?
    private(set) var saveCount = 0
    private var fails = false
    private var holds = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isWriting: Bool { continuation != nil }
    func loadWorkspace() async throws -> WorkspaceSnapshot? { snapshot }
    func saveWorkspace(_ snapshot: WorkspaceSnapshot) async throws {
        saveCount += 1
        if fails { throw DatabaseError("Synthetic disk failure") }
        if holds { await withCheckedContinuation { continuation = $0 } }
        self.snapshot = snapshot
    }
    func failWrites() { fails = true }
    func holdWrites() { holds = true }
    func finishWrites() {
        holds = false
        let pending = continuation; continuation = nil; pending?.resume()
    }
}
