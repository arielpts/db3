import Foundation
import Observation
import DB3Core

enum ObjectBrowserPhase: Equatable {
    case noSelection, notLoaded, loading, refreshing, loadingMore, loaded
    case failed, credentialsRequired, cancelled, disconnected
}

struct ObjectBrowserCredentialRequest: Identifiable, Equatable {
    let id: UUID
    let profile: ConnectionProfile
    let message: String
}

/// Only this nonsecret snapshot crosses from the browser into a query tab.
struct ObjectQuerySelection: Sendable {
    let profile: ConnectionProfile
    let database: CatalogDatabaseIdentity
    let object: DatabaseObject
}

@MainActor @Observable
final class ObjectBrowserModel {
    private(set) var selectedProfile: ConnectionProfile?
    private(set) var objects: [DatabaseObject] = []
    private(set) var schemas: [String] = []
    private(set) var schemasTruncated = false
    var selectedObjectID: DatabaseObjectID?
    private(set) var phase: ObjectBrowserPhase = .noSelection
    private(set) var isOutOfDate = false
    private(set) var hasMore = false
    private(set) var reachedDisplayLimit = false
    private(set) var lastSuccess: Date?
    private(set) var errorMessage: String?
    private(set) var credentialRequest: ObjectBrowserCredentialRequest?
    var namespaceFilter = CatalogNamespaceFilter() { didSet { if oldValue != namespaceFilter { filtersChanged() } } }
    @ObservationIgnored var didLoadObjects: (@MainActor ([DatabaseObject]) -> Void)?
    var searchText = "" { didSet { if oldValue != searchText { filtersChanged() } } }
    var kind: DatabaseObjectKind? { didSet { if oldValue != kind { filtersChanged() } } }
    var schema: String? = "public" { didSet { if oldValue != schema { filtersChanged() } } }

    @ObservationIgnored private let service: any CatalogService
    @ObservationIgnored private let credentials: @Sendable (UUID) async throws -> String
    @ObservationIgnored private let cache: ObjectCatalogCache
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var revisions: [UUID: UUID] = [:]
    @ObservationIgnored private var source: CatalogSource?
    @ObservationIgnored private var database: CatalogDatabaseIdentity?
    @ObservationIgnored private var catalogGeneration: UUID?
    @ObservationIgnored private var nextCursor: CatalogCursor?
    @ObservationIgnored private var requestGeneration = UUID()
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var sessionPassword: (source: CatalogSource, value: String)?
    @ObservationIgnored private var hasRequestedLoad = false

    init(service: any CatalogService,
         credentials: @escaping @Sendable (UUID) async throws -> String,
         debounce: Duration = .milliseconds(200), maximumRows: Int = 5_000,
         maximumBytes: Int = 8 * 1_024 * 1_024) {
        self.service = service; self.credentials = credentials; self.debounce = debounce
        cache = ObjectCatalogCache(maximumRows: maximumRows, maximumBytes: maximumBytes)
    }

    var isBusy: Bool { phase == .loading || phase == .refreshing || phase == .loadingMore }
    var selectedObject: DatabaseObject? { objects.first { $0.id == selectedObjectID } }
    var canUseObjects: Bool { phase == .loaded && !isOutOfDate }
    var hasFilters: Bool { !searchText.isEmpty || kind != nil }
    private var defaultSchema: String {
        let value = selectedProfile?.defaultSchema ?? "public"
        return value.isEmpty ? "public" : value
    }
    var schemaOptions: [String] {
        var options = schemas
        // Keep a saved/missing schema selectable even before discovery, or when
        // it has been dropped. Never silently broaden an empty schema's scope.
        if !options.contains(defaultSchema) { options.insert(defaultSchema, at: 0) }
        if let schema, !options.contains(schema) { options.insert(schema, at: 0) }
        return options
    }

    /// Restoring context uses load=false. Only explicit navigation/load starts I/O.
    func selectProfile(_ profile: ConnectionProfile?, load: Bool = true) {
        if profile == selectedProfile, source != nil {
            if load { self.load() }
            return
        }
        invalidateRequest(closeSession: true)
        selectedProfile = profile
        sessionPassword = nil; database = nil; catalogGeneration = nil
        objects = []; selectedObjectID = nil; nextCursor = nil
        hasMore = false; reachedDisplayLimit = false; lastSuccess = nil; isOutOfDate = false
        errorMessage = nil; hasRequestedLoad = false
        schemas = []; schemasTruncated = false
        schema = defaultSchema
        guard let profile else { source = nil; phase = .noSelection; return }
        let revision = revisions[profile.id] ?? UUID()
        revisions[profile.id] = revision
        source = CatalogSource(profile: profile, revision: revision)
        phase = .notLoaded
        if load { self.load() }
    }

    /// Profile edits/removal invalidate catalog ownership, never a worksheet.
    func synchronizeProfiles(_ profiles: [ConnectionProfile]) {
        guard let current = selectedProfile else { return }
        guard let replacement = profiles.first(where: { $0.id == current.id }) else {
            selectProfile(nil); return
        }
        if replacement != current {
            revisions[current.id] = UUID()
            selectProfile(replacement, load: false)
        }
    }

    func invalidateCredentials(profileID: UUID) {
        revisions[profileID] = UUID()
        guard let profile = selectedProfile, profile.id == profileID else { return }
        invalidateRequest(closeSession: true)
        source = CatalogSource(profile: profile, revision: revisions[profileID]!)
        sessionPassword = nil; nextCursor = nil; hasMore = false
        isOutOfDate = !objects.isEmpty; phase = .notLoaded
        hasRequestedLoad = false; errorMessage = nil
    }

    func load() { startRequest(append: false, delay: .zero, restoreCache: true) }
    func load(password: String) {
        guard let source else { return }
        sessionPassword = (source, password)
        load()
    }
    func refresh() { startRequest(append: false, delay: .zero) }
    func loadMore() {
        guard phase == .loaded, !isOutOfDate, hasMore, !reachedDisplayLimit, nextCursor != nil else { return }
        startRequest(append: true, delay: .zero)
    }
    func clearSearch() { searchText = "" }

    func cancel() {
        invalidateRequest(closeSession: true)
        isOutOfDate = !objects.isEmpty; phase = selectedProfile == nil ? .noSelection : .cancelled
        errorMessage = nil; sessionPassword = nil
    }

    func disconnect() {
        invalidateRequest(closeSession: true)
        isOutOfDate = !objects.isEmpty; phase = selectedProfile == nil ? .noSelection : .disconnected
        errorMessage = nil; sessionPassword = nil
    }

    func requestCredentials() {
        guard let source else { return }
        requireCredentials("Enter the password for this browser connection.", source: source)
    }

    func submitPassword(_ password: String, for requestID: UUID) {
        guard let prompt = credentialRequest, prompt.id == requestID,
              prompt.profile == selectedProfile, let source else { return }
        credentialRequest = nil
        sessionPassword = (source, password)
        load()
    }

    func dismissCredentialRequest(_ requestID: UUID) {
        guard credentialRequest?.id == requestID else { return }
        cancel()
    }

    func captureSelection() -> ObjectQuerySelection? {
        guard canUseObjects, let object = selectedObject, let source, let database,
              object.id.source == source, object.id.databaseOID == database.oid,
              object.id.generation == catalogGeneration else { return nil }
        return ObjectQuerySelection(profile: source.profile, database: database, object: object)
    }

    /// Reuse this browser's in-memory credential only for its validated source.
    /// The object snapshot and workspace recovery remain credential-free.
    func password(for selection: ObjectQuerySelection) -> String? {
        guard let current = captureSelection(), current.profile == selection.profile,
              current.database == selection.database, current.object.id == selection.object.id,
              let sessionPassword, sessionPassword.source == selection.object.id.source else { return nil }
        return sessionPassword.value
    }

    func shutdown() async {
        disconnect()
        let generation = requestGeneration
        await closeTask?.value
        guard requestGeneration == generation else { return }
        await cache.removeAll()
        guard requestGeneration == generation else { return }
        objects = []; selectedObjectID = nil; database = nil; catalogGeneration = nil
        schemas = []; schemasTruncated = false
        nextCursor = nil; hasMore = false; reachedDisplayLimit = false
        lastSuccess = nil; isOutOfDate = false
    }

    private func filtersChanged() {
        // Changing a restored/unloaded/disconnected context must not connect.
        guard selectedProfile != nil, hasRequestedLoad,
              phase != .cancelled, phase != .disconnected, phase != .notLoaded else { return }
        startRequest(append: false, delay: debounce)
    }

    private func invalidateRequest(closeSession: Bool) {
        requestGeneration = UUID(); requestTask?.cancel(); requestTask = nil
        credentialRequest = nil
        if closeSession {
            let precedingClose = closeTask
            let service = service
            closeTask = Task {
                await precedingClose?.value
                await service.disconnect()
            }
        }
    }

    private func startRequest(append: Bool, delay: Duration, restoreCache: Bool = false) {
        guard let source else { return }
        let previousDatabase = database
        let previousCatalogGeneration = catalogGeneration
        let cursor = append ? nextCursor : nil
        let key = ObjectCatalogCache.Key(source: source, search: searchText, kind: kind, schema: schema, namespaceFilter: namespaceFilter)
        invalidateRequest(closeSession: false)
        let generation = requestGeneration
        let barrier = closeTask
        hasRequestedLoad = true; errorMessage = nil
        isOutOfDate = !objects.isEmpty
        phase = append ? .loadingMore : (objects.isEmpty ? .loading : .refreshing)
        if !append { nextCursor = nil; hasMore = false; reachedDisplayLimit = false }
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                if restoreCache, objects.isEmpty, let cached = await cache.entry(for: key) {
                    guard accepts(generation, source: source) else { return }
                    apply(cached, stale: true)
                    phase = .refreshing
                }
                await barrier?.value
                try Task.checkCancellation()
                guard accepts(generation, source: source) else { return }
                let password: String
                if let saved = sessionPassword, saved.source == source { password = saved.value }
                else {
                    do { password = try await credentials(source.profile.id) }
                    catch {
                        guard accepts(generation, source: source), !Task.isCancelled else { return }
                        requireCredentials(error.localizedDescription, source: source)
                        return
                    }
                }
                try Task.checkCancellation()
                guard accepts(generation, source: source) else { return }
                let page = try await service.page(source: source, password: password,
                    query: CatalogQuery(search: key.search, kind: key.kind, schema: key.schema, cursor: cursor, namespaceFilter: key.namespaceFilter))
                try Task.checkCancellation()
                guard accepts(generation, source: source) else { return }
                guard page.database.name == source.profile.database,
                      page.objects.allSatisfy({ $0.id.source == source && $0.id.databaseOID == page.database.oid && $0.id.generation == page.generation }) else {
                    throw DatabaseError("The catalog response belongs to a different database or connection. Refresh objects to retry.")
                }
                if append, previousDatabase != page.database || previousCatalogGeneration != page.generation {
                    throw DatabaseError("The catalog connection changed while loading more objects. Refresh objects to start again.")
                }
                let entry = try await cache.store(page: page, for: key, append: append)
                try Task.checkCancellation()
                guard accepts(generation, source: source) else { return }
                sessionPassword = (source, password)
                apply(entry, stale: false)
                phase = .loaded; requestTask = nil
                didLoadObjects?(objects)
            } catch {
                guard accepts(generation, source: source) else { return }
                requestTask = nil
                isOutOfDate = !objects.isEmpty
                if error is CancellationError || Task.isCancelled {
                    phase = .cancelled; return
                }
                if let databaseError = error as? DatabaseError,
                   databaseError.sqlState?.hasPrefix("28") == true {
                    sessionPassword = nil
                    requireCredentials(databaseError.localizedDescription, source: source)
                } else {
                    phase = .failed; errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func accepts(_ generation: UUID, source: CatalogSource) -> Bool {
        requestGeneration == generation && self.source == source
    }

    private func requireCredentials(_ message: String, source: CatalogSource) {
        guard self.source == source else { return }
        // A changed credential must not reuse a previously authenticated owner,
        // and replies to an earlier password sheet cannot revive that owner.
        invalidateRequest(closeSession: true)
        let revision = UUID()
        revisions[source.profile.id] = revision
        self.source = CatalogSource(profile: source.profile, revision: revision)
        sessionPassword = nil; nextCursor = nil; hasMore = false
        isOutOfDate = !objects.isEmpty
        phase = .credentialsRequired; errorMessage = message
        credentialRequest = ObjectBrowserCredentialRequest(id: UUID(), profile: source.profile, message: message)
    }

    private func apply(_ entry: ObjectCatalogCache.Entry, stale: Bool) {
        objects = entry.objects; database = entry.database; catalogGeneration = entry.generation
        schemas = entry.schemas; schemasTruncated = entry.schemasTruncated
        nextCursor = entry.nextCursor; hasMore = entry.nextCursor != nil
        reachedDisplayLimit = entry.reachedLimit; lastSuccess = entry.lastSuccess
        isOutOfDate = stale
        if let selectedObjectID, !objects.contains(where: { $0.id == selectedObjectID }) { self.selectedObjectID = nil }
    }
}

/// Page deduplication, accounting, and LRU eviction never run on the main actor.
private actor ObjectCatalogCache {
    struct Key: Hashable, Sendable {
        let source: CatalogSource
        let search: String
        let kind: DatabaseObjectKind?
        let schema: String?
        let namespaceFilter: CatalogNamespaceFilter
    }
    struct Entry: Sendable {
        let objects: [DatabaseObject]
        let schemas: [String]
        let schemasTruncated: Bool
        let database: CatalogDatabaseIdentity
        let generation: UUID
        let nextCursor: CatalogCursor?
        let reachedLimit: Bool
        let lastSuccess: Date
        let bytes: Int
        var access: UInt64
    }
    private let maximumRows: Int
    private let maximumBytes: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(maximumRows: Int, maximumBytes: Int) {
        self.maximumRows = max(1, maximumRows); self.maximumBytes = max(1, maximumBytes)
    }
    func entry(for key: Key) -> Entry? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.access = clock; entries[key] = entry
        return entry
    }
    func removeAll() { entries.removeAll() }

    func store(page: CatalogPage, for key: Key, append: Bool) throws -> Entry {
        try Task.checkCancellation()
        let previous = append ? entries[key] : nil
        if append, previous == nil {
            throw DatabaseError("The previous object page expired. Refresh objects to start again.")
        }
        var objects = previous?.objects ?? []
        var positions = Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($0.element.id, $0.offset) })
        var bytes = previous?.bytes ?? 0
        var schemas = previous?.schemas ?? []
        var schemasTruncated = previous?.schemasTruncated ?? page.schemasTruncated
        if previous == nil {
            for schema in page.schemas {
                let size = 64 + schema.utf8.count
                guard schemas.count < 5_000, bytes + size <= maximumBytes else {
                    schemasTruncated = true; break
                }
                schemas.append(schema); bytes += size
            }
        }
        var truncated = false
        for object in page.objects {
            if let index = positions[object.id] {
                let updatedBytes = bytes - objects[index].byteCount + object.byteCount
                guard updatedBytes <= maximumBytes else { truncated = true; break }
                bytes = updatedBytes; objects[index] = object
            } else {
                guard objects.count < maximumRows, bytes + object.byteCount <= maximumBytes else { truncated = true; break }
                positions[object.id] = objects.count
                objects.append(object); bytes += object.byteCount
            }
        }
        try Task.checkCancellation()
        let reachedLimit = truncated || (objects.count >= maximumRows && page.nextCursor != nil)
        // A response too large even for one row must not masquerade as an empty database.
        if truncated, objects.isEmpty { throw DatabaseError("Catalog metadata exceeds the display memory limit. Narrow your search.") }
        clock &+= 1
        let entry = Entry(objects: objects, schemas: schemas, schemasTruncated: schemasTruncated,
            database: page.database, generation: page.generation,
            nextCursor: page.nextCursor, reachedLimit: reachedLimit, lastSuccess: Date(), bytes: bytes, access: clock)
        entries[key] = entry
        while entries.count > 32 || entries.values.reduce(0, { $0 + $1.objects.count }) > maximumRows || entries.values.reduce(0, { $0 + $1.bytes }) > maximumBytes {
            guard let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.access < $1.value.access })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
        return entry
    }
}
