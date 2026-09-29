import Foundation
import XCTest
import DB3Core
@testable import DB3Workbench

@MainActor
final class ObjectBrowserIntegrationTests: XCTestCase {
    func testOnlyExplicitBrowserNavigationLoadsAndDoesNotRetargetBusyQuery() async throws {
        let fixture = ObjectsWorkbenchFixture(); let model = fixture.model
        let queryProfile = ConnectionProfile(name: "Query", host: "query.invalid", database: "query_db")
        let browserProfile = ConnectionProfile(name: "Browser", host: "browser.invalid", database: "browser_db")
        model.profiles = [queryProfile, browserProfile]
        let original = model.active
        original.connect(queryProfile, password: "worksheet-only")
        try await eventually { original.isConnected && !original.isBusy }
        let session = fixture.sessions[0]
        await session.suspendExecution()
        original.sql = "SELECT 'long running worksheet';"
        original.run()
        try await eventually { await session.queries.count == 1 }
        let initialDisconnects = await session.disconnectCount

        model.selectedBrowserProfileID = browserProfile.id
        XCTAssertEqual(model.objectBrowser.phase, .notLoaded)
        model.addWorksheet()
        XCTAssertFalse(model.active.isConnected)
        XCTAssertEqual(model.active.profile, browserProfile)
        let initialLoads = await fixture.catalog.requests.count
        XCTAssertEqual(initialLoads, 0)
        model.selectTab(original.id)
        model.selectBrowserProfile(browserProfile)
        try await eventually { model.objectBrowser.phase == .loaded }
        XCTAssertTrue(original.isBusy)
        XCTAssertEqual(original.profile, queryProfile)
        XCTAssertEqual(original.sql, "SELECT 'long running worksheet';")
        XCTAssertTrue(model.active === original)
        let cancellations = await session.cancelCount
        let disconnections = await session.disconnectCount
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(disconnections, initialDisconnects)
        await session.finishExecution()
        try await eventually { !original.isBusy }
        await model.shutdown()
    }

    func testObjectActionQuotesNamesCapturesContextAndRespectsCapacityWithoutExecuting() async throws {
        let fixture = ObjectsWorkbenchFixture(); let model = fixture.model
        let profile = ConnectionProfile(name: "Captured", host: "original.invalid", database: "data")
        model.profiles = [profile]
        model.selectBrowserProfile(profile)
        try await eventually { model.objectBrowser.phase == .loaded }
        let object = try XCTUnwrap(model.objectBrowser.objects.first)
        model.objectBrowser.selectedObjectID = object.id
        let original = model.active; let originalSQL = original.sql
        model.openSelectedObjectQuery()
        let opened = model.active
        XCTAssertEqual(opened.sql, "SELECT *\nFROM \"Sales\"\"EU\".\"Order.Items\"\nLIMIT 1000;")
        XCTAssertEqual(opened.profile, profile)
        XCTAssertEqual(opened.queryContext?.database, "data")
        XCTAssertEqual(opened.queryContext?.schema, "Sales\"EU")
        XCTAssertEqual(opened.queryContext?.object, "Order.Items")
        XCTAssertEqual(original.sql, originalSQL)
        XCTAssertTrue(opened.isDirty)
        try await eventually { opened.isConnected && !opened.isBusy }
        let openedConnections = await fixture.sessions[1].connections
        XCTAssertEqual(openedConnections.map(\.profile), [profile])
        let originalConnections = await fixture.sessions[0].connections
        XCTAssertTrue(originalConnections.isEmpty)
        for session in fixture.sessions {
            let queries = await session.queries
            XCTAssertTrue(queries.isEmpty)
        }
        model.addWorksheet(); model.addWorksheet()
        let IDs = model.worksheets.map(\.id); let active = model.active
        let passwordReadsBeforeCapacity = await fixture.persistence.passwordReads
        model.openSelectedObjectQuery()
        model.openSelectedObjectForEditing()
        XCTAssertEqual(model.worksheets.map(\.id), IDs)
        XCTAssertTrue(model.active === active)
        XCTAssertEqual(model.error, model.tabLimitMessage)
        let passwordReadsAfterCapacity = await fixture.persistence.passwordReads
        XCTAssertEqual(passwordReadsAfterCapacity, passwordReadsBeforeCapacity)
        for session in fixture.sessions.suffix(2) {
            let connections = await session.connections
            XCTAssertTrue(connections.isEmpty, "Rejected object actions must not connect the unrelated active tab.")
        }

        model.profiles[0].host = "changed.invalid"
        XCTAssertEqual(opened.profile?.host, "original.invalid")
        XCTAssertFalse(model.objectBrowser.canUseObjects)
        model.openSelectedObjectQuery()
        XCTAssertEqual(model.worksheets.map(\.id), IDs)
        await model.shutdown()
    }

    func testEditingObjectConnectsCapturedSourceAndLeavesExistingSessionUntouched() async throws {
        let fixture = ObjectsWorkbenchFixture(); let model = fixture.model
        let originalProfile = ConnectionProfile(name: "Existing", host: "existing.invalid", database: "existing_db")
        let objectProfile = ConnectionProfile(name: "Object source", host: "objects.invalid", database: "object_db")
        model.profiles = [originalProfile, objectProfile]
        let original = model.active
        original.sql = "SELECT 'existing query';"
        original.connect(originalProfile, password: "existing-only")
        try await eventually { original.isConnected && !original.isBusy }
        let originalIntent = original.connectionIntent
        let originalDisconnects = await fixture.sessions[0].disconnectCount
        model.selectedBrowserProfileID = objectProfile.id
        model.objectBrowser.load(password: "object-only")
        try await eventually { model.objectBrowser.phase == .loaded }
        let object = try XCTUnwrap(model.objectBrowser.objects.first)
        model.objectBrowser.selectedObjectID = object.id

        model.openSelectedObjectForEditing()
        let opened = model.active
        // Change browser context before the newly allocated session completes.
        model.selectedBrowserProfileID = originalProfile.id
        try await eventually { opened.isConnected && !opened.isBusy }
        XCTAssertEqual(opened.profile, objectProfile)
        XCTAssertEqual(opened.queryContext?.database, objectProfile.database)
        XCTAssertEqual(opened.editTarget, WorksheetEditTarget(relationOID: object.id.relationOID, schema: object.schema, name: object.name))
        XCTAssertEqual(opened.ownedEditSQL, opened.sql)
        XCTAssertEqual(opened.sql, "SELECT *, xmin::text\nFROM ONLY \"Sales\"\"EU\".\"Order.Items\"\nLIMIT 1000;")
        XCTAssertEqual(opened.commitMode, .manual)
        let openedConnections = await fixture.sessions[1].connections
        XCTAssertEqual(openedConnections, [.init(profile: objectProfile, password: "object-only")])
        XCTAssertEqual(original.profile, originalProfile)
        XCTAssertEqual(original.sql, "SELECT 'existing query';")
        XCTAssertEqual(original.connectionIntent, originalIntent)
        XCTAssertTrue(original.isConnected)
        let remainingDisconnects = await fixture.sessions[0].disconnectCount
        XCTAssertEqual(remainingDisconnects, originalDisconnects)
        for session in fixture.sessions {
            let commands = await session.commands
            XCTAssertTrue(commands.isEmpty, "Opening an object connects its tab but does not run SQL.")
        }
        let passwordReads = await fixture.persistence.passwordReads
        XCTAssertTrue(passwordReads.isEmpty)
        await model.shutdown()
    }

    func testObjectQueryReusesOneShotAndEmptyBrowserPasswordsWithoutPersistence() async throws {
        let fixture = ObjectsWorkbenchFixture(); let model = fixture.model
        let profile = ConnectionProfile(name: "Session only", host: "session.invalid")
        model.profiles = [profile]
        model.selectedBrowserProfileID = profile.id
        for (index, password) in ["one-shot-secret", ""].enumerated() {
            model.objectBrowser.load(password: password)
            try await eventually { model.objectBrowser.phase == .loaded }
            let object = try XCTUnwrap(model.objectBrowser.objects.first)
            model.objectBrowser.selectedObjectID = object.id
            model.openSelectedObjectQuery()
            let opened = model.active
            try await eventually { opened.isConnected && !opened.isBusy }
            let connections = await fixture.sessions[index + 1].connections
            XCTAssertEqual(connections, [.init(profile: profile, password: password)])
            let commands = await fixture.sessions[index + 1].commands
            XCTAssertTrue(commands.isEmpty)
        }
        let reads = await fixture.persistence.passwordReads
        let passwordWrites = await fixture.persistence.passwordWrites
        let profileWrites = await fixture.persistence.profileWrites
        XCTAssertTrue(reads.isEmpty, "The authenticated browser's memory-only password also handles trust authentication.")
        XCTAssertTrue(passwordWrites.isEmpty)
        XCTAssertTrue(profileWrites.isEmpty)
        await model.shutdown()
    }

    func testStaleObjectSelectionCannotConnectOrExposeAnotherBrowserPassword() async throws {
        let fixture = ObjectsWorkbenchFixture(); let model = fixture.model
        let first = ConnectionProfile(name: "First", host: "first.invalid")
        let second = ConnectionProfile(name: "Second", host: "second.invalid")
        model.profiles = [first, second]
        model.selectedBrowserProfileID = first.id
        model.objectBrowser.load(password: "first-only")
        try await eventually { model.objectBrowser.phase == .loaded }
        model.objectBrowser.selectedObjectID = model.objectBrowser.objects.first?.id
        let firstSelection = try XCTUnwrap(model.objectBrowser.captureSelection())
        XCTAssertEqual(model.objectBrowser.password(for: firstSelection), "first-only")

        model.objectBrowser.refresh()
        XCTAssertNil(model.objectBrowser.password(for: firstSelection))
        try await eventually { model.objectBrowser.phase == .loaded }
        XCTAssertNil(model.objectBrowser.password(for: firstSelection), "A refreshed catalog generation invalidates old captures.")
        model.selectedBrowserProfileID = second.id
        model.objectBrowser.load(password: "second-only")
        try await eventually { model.objectBrowser.phase == .loaded }
        model.objectBrowser.selectedObjectID = firstSelection.object.id
        let IDs = model.worksheets.map(\.id)
        XCTAssertNil(model.objectBrowser.captureSelection())
        XCTAssertNil(model.objectBrowser.password(for: firstSelection))
        model.openSelectedObjectQuery()
        model.openSelectedObjectForEditing()
        XCTAssertEqual(model.worksheets.map(\.id), IDs)
        let connections = await fixture.sessions[0].connections
        XCTAssertTrue(connections.isEmpty)
        await model.shutdown()
    }

    func testCatalogSettingsSaveUsesOneShotPasswordAndLeavesQuerySessionAlone() async throws {
        let fixture = ObjectsWorkbenchFixture(); let model = fixture.model
        var profile = ConnectionProfile(name: "Browser", host: "old.invalid", database: "old_db")
        model.profiles = [profile]
        let original = model.active
        original.connect(profile, password: "worksheet-password")
        try await eventually { original.isConnected && !original.isBusy }
        let originalProfile = original.profile
        let originalIntent = original.connectionIntent
        model.selectedBrowserProfileID = profile.id
        model.editBrowserConnection(profile)
        let intent = try XCTUnwrap(model.catalogConnectionEditIntent)
        XCTAssertNil(model.connectionEditTarget)
        profile.host = "new.invalid"; profile.database = "new_db"
        try await model.saveCatalogConnection(profile: profile, password: "one-shot", remember: false, intent: intent)
        try await eventually { model.objectBrowser.phase == .loaded }
        let requests = await fixture.catalog.requests
        XCTAssertEqual(requests.last?.profile, profile)
        XCTAssertEqual(requests.last?.password, "one-shot")
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertEqual(original.profile, originalProfile)
        XCTAssertEqual(original.connectionIntent, originalIntent)
        let connections = await fixture.sessions[0].connections
        XCTAssertEqual(connections.count, 1)
        model.dismissConnectionEditor()
        await model.shutdown()
    }

    func testContextChangeInvalidatesCatalogSettingsIntent() async throws {
        let fixture = ObjectsWorkbenchFixture(); let model = fixture.model
        let first = ConnectionProfile(name: "First"), second = ConnectionProfile(name: "Second")
        model.profiles = [first, second]
        model.selectedBrowserProfileID = first.id
        model.editBrowserConnection(first)
        let intent = try XCTUnwrap(model.catalogConnectionEditIntent)
        model.selectedBrowserProfileID = second.id
        XCTAssertFalse(model.showingConnection)
        XCTAssertNil(model.catalogConnectionEditIntent)
        do {
            try await model.saveCatalogConnection(profile: first, password: "obsolete", remember: false, intent: intent)
            XCTFail("An obsolete editor must not load or save its profile")
        } catch { }
        let requests = await fixture.catalog.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(model.objectBrowser.selectedProfile, second)
        await model.shutdown()
    }

    func testWorkspaceCloseCancellationKeepsCatalogAndApprovedCloseWaitsForRelease() async throws {
        let fixture = ObjectsWorkbenchFixture(); let model = fixture.model
        let profile = ConnectionProfile()
        model.profiles = [profile]; model.selectBrowserProfile(profile)
        try await eventually { model.objectBrowser.phase == .loaded }
        model.active.sql = "SELECT 'unsaved';"
        model.active.transaction = .inTransaction
        fixture.dialogs.closeDecisions = [.keepOpen]
        let before = await fixture.catalog.disconnectCount
        let cancelled = await model.requestCloseWorkspace()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(model.objectBrowser.phase, .loaded)
        let after = await fixture.catalog.disconnectCount
        XCTAssertEqual(after, before)

        await fixture.catalog.suspendClose()
        fixture.dialogs.closeDecisions = [.discard]
        let closing = Task { await model.requestCloseWorkspace() }
        try await eventually { await fixture.catalog.isWaitingForClose }
        XCTAssertTrue(model.isCoordinatingClose)
        XCTAssertFalse(model.canAddWorksheet)
        XCTAssertTrue(model.worksheets.isEmpty)
        model.addWorksheet()
        XCTAssertTrue(model.worksheets.isEmpty)
        await fixture.catalog.finishClose()
        let approved = await closing.value
        XCTAssertTrue(approved)
        XCTAssertFalse(model.isCoordinatingClose)
        XCTAssertEqual(model.objectBrowser.phase, .disconnected)
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DatabaseError("Timed out waiting for object/workbench integration")
    }
}

@MainActor
private final class ObjectsWorkbenchFixture {
    let persistence = MemoryWorkbenchPersistence()
    let dialogs = ScriptedWorkbenchDialogs()
    let catalog = SelectionCatalogService()
    var sessions: [RecordingDatabaseSession] = []
    lazy var model = WorkbenchModel(persistence: persistence, dialogs: dialogs, catalogService: catalog, worksheetFactory: { [unowned self] title in
        let session = RecordingDatabaseSession(); self.sessions.append(session)
        return Worksheet(title: title, sessionFactory: { _ in session })
    })
}

private actor SelectionCatalogService: CatalogService {
    struct Request: Sendable { let profile: ConnectionProfile; let password: String }
    private(set) var requests: [Request] = []
    private(set) var disconnectCount = 0
    private var holdClose = false
    private var closeContinuation: CheckedContinuation<Void, Never>?
    var isWaitingForClose: Bool { closeContinuation != nil }
    func page(source: CatalogSource, password: String, query: CatalogQuery) async throws -> CatalogPage {
        requests.append(Request(profile: source.profile, password: password))
        let generation = UUID()
        let database = CatalogDatabaseIdentity(oid: 123, name: source.profile.database)
        let object = DatabaseObject(id: DatabaseObjectID(source: source, databaseOID: database.oid, relationOID: 456, generation: generation),
            schemaOID: 10, schema: "Sales\"EU", name: "Order.Items", kind: .table)
        return CatalogPage(objects: [object], nextCursor: nil, database: database, generation: generation)
    }
    func disconnect() async {
        disconnectCount += 1
        if holdClose { await withCheckedContinuation { closeContinuation = $0 } }
    }
    func suspendClose() { holdClose = true }
    func finishClose() {
        holdClose = false
        let continuation = closeContinuation; closeContinuation = nil
        continuation?.resume()
    }
}
