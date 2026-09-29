import Foundation
import XCTest
import DB3Core
@testable import DB3Workbench

@MainActor
final class ObjectBrowserModelTests: XCTestCase {
    func testSchemaUsesSavedDefaultAndProfileEditsDoNotAutomaticallyConnect() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        var profile = ConnectionProfile(name: "Saved")
        model.selectProfile(profile, load: false)
        XCTAssertEqual(model.schema, "public")
        profile.defaultSchema = "Sales\"EU"
        model.synchronizeProfiles([profile])
        XCTAssertEqual(model.schema, "Sales\"EU")
        XCTAssertEqual(model.schemaOptions, ["Sales\"EU"])
        model.schema = nil
        try await Task.sleep(for: .milliseconds(15))
        let unloadedRequests = await service.requests
        XCTAssertTrue(unloadedRequests.isEmpty)
        model.load()
        try await waitForRequests(1, service)
        let allSchemas = await service.requests[0].query.schema
        XCTAssertNil(allSchemas)
        await service.succeed(0, rows: [], schemas: ["empty", "public"])
        try await eventually { model.phase == .loaded }
        XCTAssertTrue(model.schemaOptions.contains("Sales\"EU"), "A missing default remains explicit instead of silently selecting another schema.")
        let other = ConnectionProfile(name: "Other")
        model.selectProfile(other, load: false)
        XCTAssertEqual(model.schema, "public")
        XCTAssertEqual(model.schemaOptions, ["public"])
        await model.shutdown()
    }

    func testSchemaChangeRestartsPaginationAndFencesLateRowsAndSchemaNames() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        let firstSchema = await service.requests[0].query.schema
        XCTAssertEqual(firstSchema, "public")
        await service.succeed(0, rows: [(1, "public-row")], more: true, schemas: ["empty", "public", "sales"])
        try await eventually { model.phase == .loaded }
        model.selectedObjectID = model.objects[0].id
        model.loadMore()
        try await waitForRequests(2, service)
        model.schema = "sales"
        XCTAssertNil(model.captureSelection())
        try await waitForRequests(3, service)
        let changed = await service.requests[2].query
        XCTAssertEqual(changed.schema, "sales")
        XCTAssertNil(changed.cursor)
        await service.succeed(2, rows: [(10, "sales-row")], more: true,
                              schemas: ["empty", "public", "sales"], schemasTruncated: true)
        try await eventually { model.phase == .loaded }
        await service.succeed(1, rows: [(2, "late-public-row")], schemas: ["obsolete"])
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(model.objects.map(\.name), ["sales-row"])
        XCTAssertEqual(model.objects.map(\.schema), ["sales"])
        XCTAssertEqual(model.schemas, ["empty", "public", "sales"])
        XCTAssertTrue(model.schemasTruncated)
        XCTAssertNil(model.selectedObjectID)
        model.loadMore()
        try await waitForRequests(4, service)
        let next = await service.requests[3].query
        XCTAssertEqual(next.schema, "sales")
        XCTAssertEqual(next.cursor?.relationOID, 10)
        await service.succeed(3, rows: [(11, "second-sales-row")])
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.schemas, ["empty", "public", "sales"], "Continuation pages retain discovery from the first page.")
        XCTAssertTrue(model.schemasTruncated)
        model.schema = nil
        try await waitForRequests(5, service)
        let all = await service.requests[4].query
        XCTAssertNil(all.schema)
        XCTAssertNil(all.cursor)
        await service.succeed(4, rows: [], schemas: ["public"])
        try await eventually { model.phase == .loaded }
        XCTAssertFalse(model.schemasTruncated)
        XCTAssertEqual(model.schemas, ["public"])
        await model.shutdown()
    }

    func testCachedRowsStayScopedToSchemaWhenReturningToConnectionDefault() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        let first = ConnectionProfile(name: "First"), second = ConnectionProfile(name: "Second")
        model.selectProfile(first)
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, "public-row")], schemas: ["public", "sales"])
        try await eventually { model.phase == .loaded }
        model.schema = "sales"
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(2, "sales-row")], schemas: ["public", "sales"])
        try await eventually { model.phase == .loaded }
        model.selectProfile(second, load: false)
        model.selectProfile(first)
        try await waitForRequests(3, service)
        XCTAssertEqual(model.schema, "public")
        XCTAssertEqual(model.objects.map(\.name), ["public-row"])
        XCTAssertTrue(model.isOutOfDate)
        await service.succeed(2, rows: [], schemas: ["public", "sales"])
        try await eventually { model.phase == .loaded }
        XCTAssertTrue(model.objects.isEmpty)
        XCTAssertTrue(model.schemaOptions.contains("sales"), "Empty results must not remove other schema choices.")
        await model.shutdown()
    }

    func testRestoringContextAndChangingFiltersDoNotConnectUntilExplicitLoad() async throws {
        let service = BrowserCatalogDouble()
        let model = makeModel(service)
        XCTAssertEqual(model.phase, .noSelection)
        let profile = ConnectionProfile(name: "Browser", database: "catalog")
        model.selectProfile(profile, load: false)
        model.searchText = "needle"; model.kind = .view
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(model.phase, .notLoaded)
        let before = await service.requests
        XCTAssertTrue(before.isEmpty)
        model.load()
        try await waitForRequests(1, service)
        let request = await service.requests[0]
        XCTAssertEqual(request.source.profile, profile)
        XCTAssertEqual(request.password, "") // Trust authentication does not require a prompt.
        XCTAssertEqual(request.query.search, "needle")
        XCTAssertEqual(request.query.kind, .view)
        await service.succeed(0, rows: [])
        try await eventually { model.phase == .loaded }
        XCTAssertTrue(model.objects.isEmpty)
        XCTAssertTrue(model.hasFilters)
        XCTAssertNil(model.credentialRequest)
        XCTAssertFalse(model.hasMore)
        await model.shutdown()
    }

    func testProfileSwitchIgnoresLateRowsAndLateAuthenticationFailures() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        let first = ConnectionProfile(name: "First", database: "first")
        let second = ConnectionProfile(name: "Second", database: "second")
        model.selectProfile(first)
        try await waitForRequests(1, service)
        model.selectProfile(second)
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(20, "new")])
        try await eventually { model.phase == .loaded }
        model.selectedObjectID = model.objects.first?.id
        let selection = try XCTUnwrap(model.captureSelection())
        XCTAssertEqual(selection.profile, second)
        XCTAssertEqual(selection.database.name, "second")
        await service.fail(0, error: DatabaseError("old authentication failure", sqlState: "28P01"))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.objects.map(\.name), ["new"])
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNil(model.credentialRequest)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(selection.object.name, "new")
        await model.shutdown()
    }

    func testDelayedCredentialReplyCannotOpenPreviousProfileOrPrompt() async throws {
        let service = BrowserCatalogDouble(); let credentials = BrowserCredentialDouble()
        let first = ConnectionProfile(name: "Delayed")
        let second = ConnectionProfile(name: "Current")
        await credentials.hold(first.id)
        let model = ObjectBrowserModel(service: service, credentials: { try await credentials.password($0) })
        model.selectProfile(first)
        try await eventually { await credentials.reads.contains(first.id) }
        model.selectProfile(second)
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, "current")])
        try await eventually { model.phase == .loaded }
        await credentials.finish(first.id, result: .failure(DatabaseError("old Keychain error")))
        try await Task.sleep(for: .milliseconds(10))
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].source.profile, second)
        XCTAssertNil(model.credentialRequest)
        XCTAssertEqual(model.objects.map(\.name), ["current"])
        await model.shutdown()
    }

    func testSearchDebouncesAndUsesServerInsteadOfPartialCache() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, "first")], more: true)
        try await eventually { model.phase == .loaded }
        model.selectedObjectID = model.objects.first?.id
        model.searchText = "b"
        model.searchText = "be"
        model.searchText = "beyond_%\\\"."
        XCTAssertEqual(model.phase, .refreshing)
        XCTAssertTrue(model.isOutOfDate)
        XCTAssertNil(model.captureSelection())
        try await waitForRequests(2, service)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].query.search, "beyond_%\\\".")
        XCTAssertNil(requests[1].query.cursor)
        await service.succeed(1, rows: [(501, "beyond_%\\\".")])
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.objects.map(\.name), ["beyond_%\\\"."])
        XCTAssertFalse(model.isOutOfDate)
        XCTAssertNil(model.selectedObjectID)
        model.clearSearch()
        try await waitForRequests(3, service)
        await service.succeed(2, rows: [])
        try await eventually { model.phase == .loaded }
        XCTAssertFalse(model.hasFilters)
        XCTAssertTrue(model.objects.isEmpty)
        await model.shutdown()
    }

    func testNewerSearchWinsEvenWhenOlderPageCompletesLast() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        model.searchText = "latest"
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(2, "latest")])
        try await eventually { model.phase == .loaded }
        await service.succeed(0, rows: [(1, "stale")])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.objects.map(\.name), ["latest"])
        await model.shutdown()
    }

    func testPaginationDeduplicatesAndStopsAtDisplayCapButSearchStillWorks() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service, maximumRows: 3)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, "a"), (2, "b")], more: true)
        try await eventually { model.phase == .loaded }
        XCTAssertTrue(model.hasMore)
        model.loadMore()
        try await waitForRequests(2, service)
        let cursor = await service.requests[1].query.cursor
        XCTAssertEqual(cursor?.relationOID, 2)
        await service.succeed(1, rows: [(2, "b-renamed"), (3, "c"), (4, "d")], more: true)
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.objects.map(\.name), ["a", "b-renamed", "c"])
        XCTAssertTrue(model.reachedDisplayLimit)
        model.loadMore()
        let count = await service.requests.count
        XCTAssertEqual(count, 2)
        model.searchText = "d"
        try await waitForRequests(3, service)
        await service.succeed(2, rows: [(4, "d")])
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.objects.map(\.name), ["d"])
        XCTAssertFalse(model.reachedDisplayLimit)
        await model.shutdown()
    }

    func testCacheEvictionIsAppWideAcrossProfiles() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service, maximumRows: 3)
        let first = ConnectionProfile(name: "A")
        let second = ConnectionProfile(name: "B")
        model.selectProfile(first)
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, "a"), (2, "b")])
        try await eventually { model.phase == .loaded }
        model.selectProfile(second)
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(3, "c"), (4, "d")])
        try await eventually { model.phase == .loaded }
        model.selectProfile(first)
        try await waitForRequests(3, service)
        XCTAssertTrue(model.objects.isEmpty, "The least-recently used profile must be evicted to respect the global row limit.")
        await service.succeed(2, rows: [(1, "a")])
        try await eventually { model.phase == .loaded }
        await model.shutdown()
    }

    func testFiftyThousandObjectsStayPagedAndBoundedAndCanBeSearchedBeyondCap() async throws {
        let service = LargeBrowserCatalogDouble(count: 50_000)
        let model = ObjectBrowserModel(service: service, credentials: { _ in "" }, debounce: .milliseconds(5))
        model.selectProfile(ConnectionProfile())
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.objects.count, 500)
        for page in 2...10 {
            model.loadMore()
            try await eventually { model.phase == .loaded }
            XCTAssertEqual(model.objects.count, page * 500)
        }
        XCTAssertTrue(model.reachedDisplayLimit)
        XCTAssertTrue(model.hasMore)
        model.loadMore()
        let requestsAtCap = await service.requestCount
        XCTAssertEqual(requestsAtCap, 10)
        model.searchText = "object_49999"
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.objects.map(\.name), ["object_49999"])
        XCTAssertFalse(model.reachedDisplayLimit)
        let maximumResponse = await service.maximumResponse
        XCTAssertEqual(maximumResponse, 500)
        await model.shutdown()
        XCTAssertTrue(model.objects.isEmpty)
    }

    func testReturningToCachedProfileShowsOnlyMatchingStaleRowsUntilReload() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        let first = ConnectionProfile(name: "First", database: "first")
        let second = ConnectionProfile(name: "Second", database: "second")
        model.selectProfile(first)
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, "first-row")])
        try await eventually { model.phase == .loaded }
        model.selectProfile(second)
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(2, "second-row")])
        try await eventually { model.phase == .loaded }
        model.selectProfile(first)
        try await waitForRequests(3, service)
        XCTAssertEqual(model.objects.map(\.name), ["first-row"])
        XCTAssertTrue(model.isOutOfDate)
        XCTAssertEqual(model.phase, .refreshing)
        XCTAssertFalse(model.canUseObjects)
        await service.succeed(2, rows: [(3, "new-first-row")])
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.objects.map(\.name), ["new-first-row"])
        await model.shutdown()
    }

    func testDecodedByteCapAndOversizedResponseNeverBecomeFalseEmpty() async throws {
        let service = BrowserCatalogDouble()
        let model = ObjectBrowserModel(service: service, credentials: { _ in "" }, maximumBytes: 1_200)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, String(repeating: "a", count: 400)), (2, String(repeating: "b", count: 400))])
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.objects.count, 1)
        XCTAssertTrue(model.reachedDisplayLimit)
        model.searchText = "huge"
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(3, String(repeating: "x", count: 2_000))])
        try await eventually { model.phase == .failed }
        XCTAssertEqual(model.objects.count, 1)
        XCTAssertTrue(model.isOutOfDate)
        XCTAssertTrue(model.errorMessage?.contains("memory limit") == true)
        await model.shutdown()
    }

    func testRefreshPreservesSelectionForRenameAndErrorRetainsStaleRows() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(10, "before")])
        try await eventually { model.phase == .loaded }
        model.selectedObjectID = model.objects[0].id
        let selectedID = model.selectedObjectID
        model.refresh()
        XCTAssertTrue(model.isOutOfDate)
        XCTAssertFalse(model.canUseObjects)
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(10, "after")])
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.selectedObjectID, selectedID)
        XCTAssertEqual(model.selectedObject?.name, "after")
        model.refresh()
        try await waitForRequests(3, service)
        await service.fail(2, error: DatabaseError("permission denied", sqlState: "42501"))
        try await eventually { model.phase == .failed }
        XCTAssertEqual(model.objects.map(\.name), ["after"])
        XCTAssertTrue(model.isOutOfDate)
        XCTAssertNil(model.captureSelection())
        XCTAssertEqual(model.errorMessage, "permission denied")
        model.load()
        try await waitForRequests(4, service)
        await service.succeed(3, rows: [])
        try await eventually { model.phase == .loaded }
        XCTAssertTrue(model.objects.isEmpty)
        XCTAssertFalse(model.isOutOfDate)
        XCTAssertNil(model.selectedObjectID)
        await model.shutdown()
    }

    func testCancelAndDisconnectDoNotAutomaticallyRetryWhenFiltersChange() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        model.cancel()
        model.searchText = "after cancel"
        await service.succeed(0, rows: [(1, "cancelled")])
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertTrue(model.objects.isEmpty)
        var count = await service.requests.count
        XCTAssertEqual(count, 1)
        model.load()
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(2, "retried")])
        try await eventually { model.phase == .loaded }
        model.disconnect()
        model.kind = .materializedView
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(model.phase, .disconnected)
        count = await service.requests.count
        XCTAssertEqual(count, 2)
        XCTAssertTrue(model.isOutOfDate)
        await model.shutdown()
    }

    func testCredentialsArePurposeScopedAndProfileEditsInvalidateSavedReplies() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        var profile = ConnectionProfile(name: "Saved")
        model.selectProfile(profile)
        try await waitForRequests(1, service)
        await service.fail(0, error: DatabaseError("password required", sqlState: "28P01"))
        try await eventually { model.phase == .credentialsRequired }
        let obsoletePrompt = try XCTUnwrap(model.credentialRequest)
        profile.host = "changed.example"
        model.synchronizeProfiles([profile])
        XCTAssertEqual(model.phase, .notLoaded)
        XCTAssertNil(model.credentialRequest)
        model.submitPassword("must-not-be-used", for: obsoletePrompt.id)
        try await Task.sleep(for: .milliseconds(10))
        let before = await service.requests.count
        XCTAssertEqual(before, 1)
        model.load()
        try await waitForRequests(2, service)
        await service.fail(1, error: DatabaseError("password required", sqlState: "28P01"))
        try await eventually { model.credentialRequest != nil }
        let prompt = try XCTUnwrap(model.credentialRequest)
        model.submitPassword("session-only", for: prompt.id)
        try await waitForRequests(3, service)
        let request = await service.requests[2]
        XCTAssertEqual(request.password, "session-only")
        XCTAssertEqual(request.source.profile.host, "changed.example")
        await service.succeed(2, rows: [(1, "accepted")])
        try await eventually { model.phase == .loaded }
        let firstRevision = request.source.revision
        model.invalidateCredentials(profileID: profile.id)
        model.load(password: "new-session-only")
        try await waitForRequests(4, service)
        let next = await service.requests[3]
        XCTAssertNotEqual(next.source.revision, firstRevision)
        XCTAssertEqual(next.password, "new-session-only")
        await service.succeed(3, rows: [])
        try await eventually { model.phase == .loaded }
        await model.shutdown()
    }

    func testExplicitPasswordRetryClosesAuthenticatedOwnerAndFencesDismissedPrompt() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, "before")])
        try await eventually { model.phase == .loaded }
        let original = await service.requests[0].source
        model.selectedObjectID = model.objects.first?.id
        model.requestCredentials()
        let obsolete = try XCTUnwrap(model.credentialRequest)
        XCTAssertEqual(model.phase, .credentialsRequired)
        XCTAssertNil(model.captureSelection())
        model.requestCredentials()
        let current = try XCTUnwrap(model.credentialRequest)
        XCTAssertNotEqual(current.id, obsolete.id)
        model.submitPassword("obsolete", for: obsolete.id)
        model.dismissCredentialRequest(obsolete.id)
        XCTAssertEqual(model.credentialRequest?.id, current.id)
        model.submitPassword("replacement", for: current.id)
        try await waitForRequests(2, service)
        let request = await service.requests[1]
        XCTAssertNotEqual(request.source.revision, original.revision)
        XCTAssertEqual(request.password, "replacement")
        await service.succeed(1, rows: [(2, "after")])
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(model.objects.map(\.name), ["after"])
        let closes = await service.disconnects
        XCTAssertGreaterThanOrEqual(closes, 3)
        await model.shutdown()
    }

    func testProfileRemovalAndShutdownFenceInflightRequests() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        let profile = ConnectionProfile()
        model.selectProfile(profile)
        try await waitForRequests(1, service)
        model.synchronizeProfiles([])
        await service.succeed(0, rows: [(1, "removed")])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.phase, .noSelection)
        XCTAssertTrue(model.objects.isEmpty)
        model.selectProfile(profile)
        try await waitForRequests(2, service)
        await model.shutdown()
        await service.succeed(1, rows: [(2, "closed")])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertTrue(model.objects.isEmpty)
    }

    func testChangedDatabaseOrGenerationCannotAppendIncompatiblePage() async throws {
        let service = BrowserCatalogDouble(); let model = makeModel(service)
        model.selectProfile(ConnectionProfile())
        try await waitForRequests(1, service)
        await service.succeed(0, rows: [(1, "first")], more: true)
        try await eventually { model.phase == .loaded }
        model.loadMore()
        try await waitForRequests(2, service)
        await service.succeed(1, rows: [(2, "other session")], generation: UUID())
        try await eventually { model.phase == .failed }
        XCTAssertEqual(model.objects.map(\.name), ["first"])
        XCTAssertTrue(model.isOutOfDate)
        XCTAssertNil(model.captureSelection())
        await model.shutdown()
    }

    private func makeModel(_ service: BrowserCatalogDouble, maximumRows: Int = 5_000) -> ObjectBrowserModel {
        ObjectBrowserModel(service: service, credentials: { _ in "" }, debounce: .milliseconds(5), maximumRows: maximumRows)
    }
    private func waitForRequests(_ count: Int, _ service: BrowserCatalogDouble) async throws {
        try await eventually { await service.requests.count >= count }
    }
    private func eventually(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { XCTFail("Condition did not become true", file: file, line: line); throw BrowserTestTimeout() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct BrowserTestTimeout: Error {}

/// Intentionally ignores task cancellation until a reply is supplied, proving
/// model generations fence late data/errors even when an external owner is slow.
private actor BrowserCatalogDouble: CatalogService {
    struct Request: Sendable {
        let source: CatalogSource
        let password: String
        let query: CatalogQuery
    }
    private(set) var requests: [Request] = []
    private(set) var disconnects = 0
    private var continuations: [Int: CheckedContinuation<CatalogPage, any Error>] = [:]
    private var generations: [CatalogSource: UUID] = [:]

    func page(source: CatalogSource, password: String, query: CatalogQuery) async throws -> CatalogPage {
        let index = requests.count
        requests.append(Request(source: source, password: password, query: query))
        if generations[source] == nil { generations[source] = UUID() }
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func disconnect() async { disconnects += 1 }
    func succeed(_ index: Int, rows: [(UInt32, String)], more: Bool = false, generation: UUID? = nil,
                 schemas: [String] = [], schemasTruncated: Bool = false) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        let request = requests[index]
        let generation = generation ?? generations[request.source]!
        let objects = rows.map { oid, name in
            DatabaseObject(id: DatabaseObjectID(source: request.source, databaseOID: 12,
                relationOID: oid, generation: generation), schemaOID: 20,
                schema: request.query.schema ?? "public", name: name, kind: request.query.kind ?? .table)
        }
        let cursor = more ? objects.last.map { CatalogCursor(schema: $0.schema, name: $0.name, relationOID: $0.id.relationOID) } : nil
        continuation.resume(returning: CatalogPage(objects: objects, nextCursor: cursor,
            database: CatalogDatabaseIdentity(oid: 12, name: request.source.profile.database), generation: generation,
            schemas: schemas, schemasTruncated: schemasTruncated))
    }
    func fail(_ index: Int, error: DatabaseError) { continuations.removeValue(forKey: index)?.resume(throwing: error) }
}

private actor BrowserCredentialDouble {
    private var held: Set<UUID> = []
    private var continuations: [UUID: CheckedContinuation<String, any Error>] = [:]
    private(set) var reads: [UUID] = []
    func hold(_ id: UUID) { held.insert(id) }
    func password(_ id: UUID) async throws -> String {
        reads.append(id)
        if held.contains(id) { return try await withCheckedThrowingContinuation { continuations[id] = $0 } }
        return ""
    }
    func finish(_ id: UUID, result: Result<String, any Error>) {
        held.remove(id)
        continuations.removeValue(forKey: id)?.resume(with: result)
    }
}

/// Synthesizes 50,000 catalog rows on demand; it never materializes the full
/// catalog and exposes whether presentation requests accidentally become unbounded.
private actor LargeBrowserCatalogDouble: CatalogService {
    private let count: Int
    private let generation = UUID()
    private(set) var requestCount = 0
    private(set) var maximumResponse = 0
    init(count: Int) { self.count = count }
    func disconnect() async {}
    func page(source: CatalogSource, password: String, query: CatalogQuery) async throws -> CatalogPage {
        try Task.checkCancellation()
        requestCount += 1
        let start = Int(query.cursor?.relationOID ?? 0)
        let indices: [Int]
        if query.search.isEmpty { indices = Array(start..<min(start + query.limit, count)) }
        else { indices = (0..<count).lazy.filter { String(format: "object_%05d", $0).contains(query.search) }.prefix(query.limit).map { $0 } }
        let objects = indices.map { index in
            DatabaseObject(id: DatabaseObjectID(source: source, databaseOID: 42,
                relationOID: UInt32(index + 1), generation: generation), schemaOID: 2200,
                schema: "public", name: String(format: "object_%05d", index), kind: .table)
        }
        maximumResponse = max(maximumResponse, objects.count)
        let cursor = query.search.isEmpty && start + objects.count < count ? objects.last.map {
            CatalogCursor(schema: $0.schema, name: $0.name, relationOID: $0.id.relationOID)
        } : nil
        return CatalogPage(objects: objects, nextCursor: cursor,
            database: CatalogDatabaseIdentity(oid: 42, name: source.profile.database), generation: generation)
    }
}
