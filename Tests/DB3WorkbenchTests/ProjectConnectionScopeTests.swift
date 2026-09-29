import Foundation
import XCTest
import DB3Core
import DB3Projects
@testable import DB3Workbench

@MainActor
final class ProjectConnectionScopeTests: XCTestCase {
    func testEmptyProjectClearsGlobalObjectsWithoutChangingExistingQuery() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let global = ConnectionProfile(name: "Global", host: "global.invalid")
            let other = ConnectionProfile(name: "Other", host: "other.invalid")
            model.profiles = [global, other]
            XCTAssertEqual(model.visibleProfiles, [global, other])
            let original = model.active
            original.sql = "SELECT 'keep this query';"
            original.connect(global, password: "query-only")
            try await eventually { original.isConnected && !original.isBusy }
            model.selectBrowserProfile(global)
            try await eventually { model.objectBrowser.phase == .loaded }
            model.objectBrowser.selectedObjectID = model.objectBrowser.objects.first?.id
            XCTAssertNotNil(model.objectBrowser.captureSelection())

            await fixture.project.open(fixture.firstRoot)
            try await settled(fixture.project)
            XCTAssertTrue(model.visibleProfiles.isEmpty)
            XCTAssertNil(model.selectedBrowserProfileID)
            XCTAssertNil(model.objectBrowser.selectedProfile)
            XCTAssertTrue(model.objectBrowser.objects.isEmpty)
            XCTAssertNil(model.objectBrowser.captureSelection())
            XCTAssertEqual(model.objectBrowser.phase, .noSelection)
            XCTAssertEqual(original.profile, global)
            XCTAssertTrue(original.isConnected)
            XCTAssertEqual(original.sql, "SELECT 'keep this query';")

            model.addWorksheet()
            XCTAssertNil(model.active.profile, "New project tabs must not inherit an unrelated active tab's connection.")
            model.selectBrowserProfile(global)
            model.selectedBrowserProfileID = other.id
            XCTAssertNil(model.selectedBrowserProfileID)
            XCTAssertNil(model.objectBrowser.selectedProfile)
            let requests = await fixture.catalog.requests
            XCTAssertEqual(requests.count, 1, "Changing project scope must not connect to any database.")
            let connections = await fixture.sessions[0].connections
            XCTAssertEqual(connections.count, 1)
        }
    }

    func testBindingsScopeConnectionsAcrossProjectSwitchesAndClose() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let global = ConnectionProfile(name: "Global")
            let first = ConnectionProfile(name: "First project")
            let second = ConnectionProfile(name: "Second project")
            model.profiles = [global, first, second]
            model.selectedBrowserProfileID = global.id
            await fixture.project.open(fixture.firstRoot)
            try await settled(fixture.project)
            let firstBound = await fixture.project.bind(profile: first, key: "database", schema: "public", candidateID: nil)
            XCTAssertTrue(firstBound)
            try await settled(fixture.project)
            XCTAssertEqual(model.visibleProfiles, [first])
            XCTAssertEqual(model.objectBrowser.selectedProfile, first)
            XCTAssertEqual(model.objectBrowser.phase, .notLoaded)
            model.addWorksheet()
            let retainedTab = model.active
            XCTAssertEqual(retainedTab.profile, first)

            await fixture.project.open(fixture.secondRoot)
            try await settled(fixture.project)
            XCTAssertTrue(model.visibleProfiles.isEmpty)
            XCTAssertNil(model.objectBrowser.selectedProfile)
            XCTAssertEqual(retainedTab.profile, first)
            let secondBound = await fixture.project.bind(profile: second, key: "database", schema: "public", candidateID: nil)
            XCTAssertTrue(secondBound)
            try await settled(fixture.project)
            XCTAssertEqual(model.visibleProfiles, [second])
            XCTAssertEqual(model.objectBrowser.selectedProfile, second)

            await fixture.project.open(fixture.firstRoot)
            try await settled(fixture.project)
            XCTAssertEqual(model.visibleProfiles, [first], "Returning to a project restores its saved associations.")
            XCTAssertEqual(model.objectBrowser.selectedProfile, first)
            fixture.project.close()
            try await eventually { !fixture.project.isOpen }
            XCTAssertEqual(model.visibleProfiles, [global, first, second])
            XCTAssertEqual(retainedTab.profile, first)
            let requests = await fixture.catalog.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testChangedEndpointAndReviewRequiredBindingRemainVisibleForRepair() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let global = ConnectionProfile(name: "Global")
            var bound = ConnectionProfile(name: "Bound", host: "original.invalid")
            model.profiles = [global, bound]
            await fixture.project.open(fixture.firstRoot)
            try await settled(fixture.project)
            let accepted = await fixture.project.bind(profile: bound, key: "database", schema: "public", candidateID: nil)
            XCTAssertTrue(accepted)
            try await settled(fixture.project)

            bound.host = "changed.invalid"
            model.profiles = [global, bound]
            XCTAssertNil(fixture.project.binding(for: bound))
            XCTAssertEqual(model.visibleProfiles, [bound])
            XCTAssertEqual(model.objectBrowser.selectedProfile, bound)

            try #"{"version":1,"bindings":{}}"#.write(
                to: fixture.firstRoot.appendingPathComponent(".db3/project.json"), atomically: true, encoding: .utf8)
            fixture.project.refresh(force: true)
            try await eventually {
                fixture.project.reviewRequired.contains("database") && fixture.project.status != .inspecting
            }
            XCTAssertNil(fixture.project.binding(for: bound))
            XCTAssertEqual(model.visibleProfiles, [bound], "Connections awaiting binding review must remain available for repair.")
            XCTAssertEqual(model.objectBrowser.selectedProfile, bound)
            let requests = await fixture.catalog.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testUnboundSaveDoesNotLoadUntilBindingAndExplicitCatalogLoad() async throws {
        try await withFixture { fixture in
            let model = fixture.model
            let global = ConnectionProfile(name: "Global")
            let candidate = ConnectionProfile(name: "Candidate", host: "candidate.invalid")
            model.profiles = [global]
            model.active.profile = global
            await fixture.project.open(fixture.firstRoot)
            try await settled(fixture.project)
            model.editBrowserConnection(candidate)
            let intent = try XCTUnwrap(model.catalogConnectionEditIntent)
            try await model.saveCatalogConnection(profile: candidate, password: "one-shot", remember: false, intent: intent)
            XCTAssertTrue(model.visibleProfiles.isEmpty)
            XCTAssertNil(model.objectBrowser.selectedProfile)
            let beforeBinding = await fixture.catalog.requests
            XCTAssertTrue(beforeBinding.isEmpty)
            XCTAssertEqual(model.profiles, [global, candidate], "Saving must retain the profile for explicit project binding.")

            let accepted = await fixture.project.bind(profile: candidate, key: "database", schema: "public", candidateID: nil)
            XCTAssertTrue(accepted)
            try await settled(fixture.project)
            XCTAssertEqual(model.visibleProfiles, [candidate])
            XCTAssertEqual(model.objectBrowser.phase, .notLoaded)
            let afterBinding = await fixture.catalog.requests
            XCTAssertTrue(afterBinding.isEmpty)
            model.loadCatalogConnection(candidate, password: "one-shot")
            try await eventually { model.objectBrowser.phase == .loaded }
            let requests = await fixture.catalog.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.profile, candidate)
            XCTAssertEqual(requests.first?.password, "one-shot")
            XCTAssertEqual(model.active.profile, global)
        }
    }

    private func settled(_ project: ProjectWorkspaceModel) async throws {
        try await eventually { project.configuration != nil && project.status != .inspecting && !project.savingSettings }
    }
    private func eventually(_ predicate: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            if ContinuousClock.now >= deadline {
                XCTFail("Project connection scope did not reach the expected state", file: file, line: line)
                throw DatabaseError("Timed out waiting for project connection scope")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func withFixture(_ action: (ProjectConnectionScopeFixture) async throws -> Void) async throws {
        let fixture = try ProjectConnectionScopeFixture()
        do { try await action(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }
}

@MainActor
private final class ProjectConnectionScopeFixture {
    let base: URL
    let firstRoot: URL
    let secondRoot: URL
    let project: ProjectWorkspaceModel
    let catalog = ProjectScopeCatalogService()
    var sessions: [RecordingDatabaseSession] = []
    lazy var model = WorkbenchModel(persistence: MemoryWorkbenchPersistence(), dialogs: ScriptedWorkbenchDialogs(),
        catalogService: catalog, project: project, worksheetFactory: { [unowned self] title in
            let session = RecordingDatabaseSession(); self.sessions.append(session)
            return Worksheet(title: title, sessionFactory: { _ in session })
        })

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("db3-project-scope-" + UUID().uuidString)
        firstRoot = base.appendingPathComponent("first")
        secondRoot = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        project = ProjectWorkspaceModel(privateStore: ProjectPrivateStore(directory: base.appendingPathComponent("private")))
    }
    func close() async {
        await project.shutdown()
        await model.shutdown()
        try? FileManager.default.removeItem(at: base)
    }
}

private actor ProjectScopeCatalogService: CatalogService {
    struct Request: Sendable { let profile: ConnectionProfile; let password: String }
    private(set) var requests: [Request] = []

    func page(source: CatalogSource, password: String, query: CatalogQuery) async throws -> CatalogPage {
        requests.append(Request(profile: source.profile, password: password))
        let generation = UUID()
        let database = CatalogDatabaseIdentity(oid: 123, name: source.profile.database)
        let object = DatabaseObject(id: .init(source: source, databaseOID: database.oid, relationOID: 456, generation: generation),
            schemaOID: 10, schema: "public", name: "synthetic_table", kind: .table)
        return CatalogPage(objects: [object], nextCursor: nil, database: database, generation: generation)
    }
    func disconnect() async { }
}
