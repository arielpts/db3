import AppKit
import Foundation
import Observation
import CryptoKit
import DB3Core
import DB3Projects

struct ProjectNamespaceGroup: Identifiable {
    let id: String
    let title: String
    let objects: [DatabaseObject]
}

struct ProjectConnectionReview: Sendable {
    let projectID: UUID?
    let generation: UUID
    let candidateID: String
    let fingerprint: String
    let secretRevision: String
}

@MainActor @Observable
final class ProjectWorkspaceModel {
    enum Status: String { case inspecting = "Inspecting", current = "Up to date", changed = "Changed", partial = "Partially inspected", unavailable = "Unavailable" }
    private(set) var metadataRevision = UUID()
    private(set) var root: URL?
    private(set) var recent: ProjectRecent?
    private(set) var recents: [ProjectRecent] = []
    private(set) var missingRecent: ProjectRecent?
    private(set) var snapshot: ProjectInspectionSnapshot?
    private(set) var configuration: ProjectConfigurationSnapshot?
    private(set) var status: Status = .unavailable
    private(set) var lastSuccess: Date?
    private(set) var settings: ProjectSettingsDocument?
    private(set) var bindings: [String: ProjectPrivateBinding] = [:]
    private(set) var changedCandidates: [String: String] = [:]
    private(set) var reviewRequired: Set<String> = []
    private(set) var settingsError: String?
    private(set) var error: String?
    private(set) var unsavedSettings = false
    private(set) var savingSettings = false
    var showingDetails = false
    var inspectedModel: ProjectModelMetadata?
    var selectedNamespace: String? { didSet { if oldValue != selectedNamespace { didChange?() } } }
    var showBase: Bool { settings?.settings.namespaces.showBase ?? false }
    var name: String { recent?.name ?? root?.lastPathComponent ?? "Project" }
    var isOpen: Bool { root != nil }
    var namespaceNames: [String] {
        let inferred = Set(namespaceByTable.values).union(settings?.settings.objectOverrides.map(\.namespace) ?? [])
        let order = settings?.settings.namespaces.order ?? []
        return inferred.sorted { a, b in
            let left = order.firstIndex(of: a) ?? Int.max, right = order.firstIndex(of: b) ?? Int.max
            return left == right ? a.localizedStandardCompare(b) == .orderedAscending : left < right
        }
    }
    @ObservationIgnored var didChange: (@MainActor () -> Void)?
    @ObservationIgnored private let privateStore: ProjectPrivateStore
    @ObservationIgnored private let inspector = ProjectSourceInspector()
    @ObservationIgnored private var settingsStore: ProjectSettingsStore?
    @ObservationIgnored private var watcher: ProjectFolderWatcher?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var modelByTable: [String: ProjectModelMetadata] = [:]
    @ObservationIgnored private var namespaceByTable: [String: String] = [:]
    @ObservationIgnored private var providers: [UUID: (profile: String, binding: String, provider: ProjectMetadataProvider)] = [:]
    @ObservationIgnored private var acceptedSecrets: [String: String] = [:]
    @ObservationIgnored private var pendingPaths: Set<String> = []
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var securityScoped = false

    init(privateStore: ProjectPrivateStore = ProjectPrivateStore()) { self.privateStore = privateStore }

    func loadRecents() async {
        do {
            let state = try await privateStore.load(); recents = state.recents
            if let root, watcher == nil, periodicTask == nil {
                await open(root, replacing: recent?.id)
            } else if root == nil, let id = state.activeProjectID, let item = state.recents.first(where: { $0.id == id }) {
                do { let resolved = try await privateStore.resolve(item); await open(resolved.url, replacing: item.id) }
                catch { missingRecent = item; self.error = "The previous project folder is unavailable. Locate its new folder to restore the binding."; showingDetails = true }
            }
        } catch { self.error = "Recent projects could not be loaded." }
    }
    func chooseFolder(relocating item: ProjectRecent? = nil) {
        guard !savingSettings else { error = "Wait for project settings to finish saving."; return }
        guard !unsavedSettings else { error = "Reload or retry the unsaved project settings before changing folders."; showingDetails = true; return }
        Task {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.prompt = item == nil ? "Open Project" : "Locate Project"
            if await panel.begin() == .OK, let url = panel.url { await open(url, replacing: item?.id) }
        }
    }
    func openRecent(_ item: ProjectRecent) {
        guard !unsavedSettings, !savingSettings else { error = "Resolve the pending project settings before changing folders."; showingDetails = true; return }
        Task {
            do { let resolved = try await privateStore.resolve(item); await open(resolved.url, replacing: item.id) }
            catch { missingRecent = item; self.error = "This project folder is unavailable. Locate its new folder to restore the binding."; showingDetails = true }
        }
    }
    func open(_ url: URL, replacing: UUID? = nil) async {
        guard !unsavedSettings, !savingSettings else { return }
        settings = nil; recent = nil; settingsStore = nil; bindings = [:]
        let token = await stopInspection()
        guard token == generation else { return }
        missingRecent = nil
        root = url; securityScoped = url.startAccessingSecurityScopedResource()
        metadataRevision = UUID()
        snapshot = nil; configuration = nil; bindings = [:]; selectedNamespace = nil; inspectedModel = nil; modelByTable = [:]
        namespaceByTable = [:]; changedCandidates = [:]; reviewRequired = []; acceptedSecrets = [:]
        settingsError = nil; error = nil; status = .inspecting; lastSuccess = nil
        didChange?()
        let store = ProjectSettingsStore(root: url); settingsStore = store
        do {
            let item = try await privateStore.remember(root: url, replacing: replacing)
            let state = try await privateStore.load()
            guard token == generation else { return }
            recent = item; recents = state.recents; bindings = state.bindings[item.id.uuidString] ?? [:]
            do { settings = try await store.load() }
            catch { settings = nil; settingsError = error.localizedDescription }
            guard token == generation else { return }
            await startWatcher(url, token: token)
            guard token == generation else { return }
            refresh(force: true)
        } catch { guard token == generation else { return }; status = .unavailable; self.error = "This project folder could not be opened safely." }
        didChange?()
    }
    func close() {
        guard !unsavedSettings, !savingSettings else { error = "Reload or retry the unsaved project settings before closing."; showingDetails = true; return }
        Task {
            let token = await stopInspection()
            guard token == generation else { return }
            root = nil; recent = nil; snapshot = nil; configuration = nil
            metadataRevision = UUID()
            bindings = [:]; settings = nil; namespaceByTable = [:]; modelByTable = [:]; inspectedModel = nil; selectedNamespace = nil
            try? await privateStore.setActiveProject(nil)
            didChange?()
        }
    }
    func shutdown() async { _ = await stopInspection() }
    @discardableResult private func stopInspection() async -> UUID {
        generation = UUID(); let token = generation
        metadataRevision = UUID(); didChange?()
        scanTask?.cancel(); scanTask = nil; periodicTask?.cancel(); periodicTask = nil
        let oldWatcher = watcher; watcher = nil; pendingPaths = []; rescanPending = false
        let oldRoot = root, oldScope = securityScoped, oldProviders = Array(providers.values)
        securityScoped = false
        await Task.detached(priority: .utility) { oldWatcher?.stop() }.value
        if oldScope { oldRoot?.stopAccessingSecurityScopedResource() }
        guard token == generation else { return token }
        await inspector.cancel()
        guard token == generation else { return token }
        for value in oldProviders {
            await value.provider.suspend()
            guard token == generation else { return token }
        }
        return token
    }
    func releaseProvider(worksheetID: UUID) async {
        guard let value = providers.removeValue(forKey: worksheetID) else { return }
        await value.provider.suspend()
    }

    private func startWatcher(_ url: URL, token: UUID) async {
        let result = await Task.detached(priority: .utility) { [weak self] in
            Result { () throws -> ProjectFolderWatcher in
                let watcher = ProjectFolderWatcher(root: url) { [weak self] batch in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.status = .changed
                        self.refresh(changedPaths: batch.paths, force: batch.requiresFullRescan)
                    }
                }
                try watcher.start(); return watcher
            }
        }.value
        guard token == generation else {
            if case .success(let oldWatcher) = result { await Task.detached(priority: .utility) { oldWatcher.stop() }.value }
            return
        }
        switch result {
        case .success(let watcher): self.watcher = watcher
        case .failure: self.error = "Live project watching is unavailable. Periodic reconciliation remains enabled."
        }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.generation == token else { return }
                self.refresh()
            }
        }
    }

    func refresh(changedPaths: Set<String> = [], force: Bool = false) {
        guard let root else { return }
        if scanTask != nil {
            if force || rescanPending || pendingPaths.count + changedPaths.count >= 4096 {
                pendingPaths.removeAll(keepingCapacity: false); rescanPending = true
            } else { pendingPaths.formUnion(changedPaths) }
            return
        }
        let token = generation, previous = configuration
        status = .inspecting
        scanTask = Task {
            do {
                async let source = inspector.inspect(root: root, generation: UUID(), changedPaths: changedPaths, force: force)
                async let config = ProjectConfigurationDiscovery.discover(root: root)
                let (result, candidates) = try await (source, config)
                let modelsByTable = await Task.detached(priority: .utility) {
                    Dictionary(grouping: result.models.filter { !$0.requiresExplicitMapping && $0.tableName != nil && $0.definingModule != nil && ($0.resolution == .resolved || $0.resolution == .inferred) }, by: { $0.tableName! })
                        .compactMapValues { values -> ProjectModelMetadata? in
                            guard values.count == 1 else { return nil }; return values.first
                        }
                }.value
                guard token == generation, !Task.isCancelled else { return }
                let changed = snapshot?.rootDigest != result.rootDigest || configuration?.revision != candidates.revision
                snapshot = result; configuration = candidates; modelByTable = modelsByTable
                namespaceByTable = modelsByTable.mapValues { $0.isBase ? "base" : $0.namespace }
                if result.completeness != .unavailable { lastSuccess = result.inspectedAt }
                status = result.completeness == .unavailable ? .unavailable : (result.completeness == .partial || !candidates.complete ? .partial : .current)
                detectCandidateChanges(previous, candidates)
                if let store = settingsStore, !savingSettings {
                    do {
                        let disk = try await store.load()
                        guard token == generation else { return }
                        if disk.digest != settings?.digest {
                            if unsavedSettings { settingsError = "Project settings changed externally. Reload to discard local changes, or resolve the file before retrying."; markBindingsUnavailable("Project settings conflict; review the binding") }
                            else {
                                if settings?.settings.bindings != disk.settings.bindings { markBindingsUnavailable("Portable bindings changed; review the binding") }
                                settings = disk; didChange?()
                            }
                        }
                    } catch { guard token == generation else { return }; settingsError = error.localizedDescription; markBindingsUnavailable("Project settings unavailable; review the binding") }
                }
                if changed {
                    metadataRevision = UUID()
                    for item in providers.values {
                        await item.provider.update(result)
                        guard token == generation else { await item.provider.suspend(); return }
                    }
                    guard token == generation else { return }
                    didChange?()
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                metadataRevision = UUID()
                for (key, binding) in bindings where binding.candidateID != nil { reviewRequired.insert(key); changedCandidates[key] = "Inspection unavailable; review source configuration" }
                status = .unavailable; self.error = "Project inspection could not finish. Check folder access and refresh."
                for item in providers.values { await item.provider.suspend() }
                didChange?()
            }
            guard token == generation else { return }
            scanTask = nil
            if !pendingPaths.isEmpty || rescanPending {
                let paths = pendingPaths, full = rescanPending; pendingPaths = []; rescanPending = false
                refresh(changedPaths: paths, force: full)
            }
        }
    }
    private func markBindingsUnavailable(_ reason: String) {
        metadataRevision = UUID()
        for key in bindings.keys { reviewRequired.insert(key); changedCandidates[key] = reason }
        didChange?()
    }
    private func detectCandidateChanges(_ previous: ProjectConfigurationSnapshot?, _ current: ProjectConfigurationSnapshot) {
        for (key, binding) in bindings {
            guard let id = binding.candidateID else { continue }
            let latest = current.candidates.first { $0.id == id }
            let prior = previous?.candidates.first { $0.id == id }
            if acceptedSecrets[key] == nil, let latest, latest.nonsecretFingerprint == binding.candidateFingerprint {
                acceptedSecrets[key] = latest.secretRevision
            }
            let secretChanged = acceptedSecrets[key].map { $0 != latest?.secretRevision } ?? false
            if latest == nil || latest?.nonsecretFingerprint != binding.candidateFingerprint || secretChanged {
                reviewRequired.insert(key)
                var fields: [String] = []
                if prior?.host != latest?.host { fields.append("host") }
                if prior?.database != latest?.database { fields.append("database") }
                if prior?.environment != latest?.environment { fields.append("environment") }
                if prior?.tls != latest?.tls { fields.append("TLS") }
                if secretChanged { fields.append("credentials") }
                changedCandidates[key] = latest == nil ? "Source candidate removed" : "Changed: " + (fields.isEmpty ? "configuration or provenance" : fields.joined(separator: ", "))
            }
        }
    }
    static func endpointFingerprint(_ profile: ConnectionProfile) -> String {
        let parts = [profile.id.uuidString, profile.host, String(profile.port), profile.database, profile.username, profile.tls.rawValue, profile.rootCertificate]
        return SHA256.hash(data: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Keep associated profiles visible even when their metadata binding needs review.
    var connectionProfileIDs: Set<UUID> { Set(bindings.values.map(\.profileID)) }

    func binding(for profile: ConnectionProfile) -> (key: String, value: ProjectPrivateBinding)? {
        let matches = bindings.filter { $0.value.profileID == profile.id && $0.value.endpointFingerprint == Self.endpointFingerprint(profile) }
        guard matches.count == 1, let match = matches.first, !reviewRequired.contains(match.key),
              let portable = settings?.settings.bindings[match.key],
              portable.sourceGroup == (configuration?.candidates.first { $0.id == match.value.candidateID }?.sourceGroup ?? "manual") else { return nil }
        return (match.key, match.value)
    }
    func policyRestriction(for profile: ConnectionProfile) -> ConnectionEnvironment? {
        let matches = bindings.filter { $0.value.profileID == profile.id }
        if matches.contains(where: { item in
            let group = configuration?.candidates.first { $0.id == item.value.candidateID }?.sourceGroup ?? "manual"
            return reviewRequired.contains(item.key) || item.value.endpointFingerprint != Self.endpointFingerprint(profile)
                || settings?.settings.bindings[item.key]?.sourceGroup != group
        }) { return .unknown }
        if matches.contains(where: { item in configuration?.candidates.contains { $0.id == item.value.candidateID && $0.environment == .production } == true }) { return .production }
        return nil
    }
    func provider(for profile: ConnectionProfile, worksheetID: UUID) async throws -> ProjectMetadataProvider? {
        let requestGeneration = generation, requestRevision = metadataRevision
        guard let bound = binding(for: profile), root != nil else {
            if let existing = providers[worksheetID] {
                await existing.provider.suspend()
                guard requestGeneration == generation, requestRevision == metadataRevision else {
                    throw DatabaseError("The project changed while preparing query metadata. Run the query again.")
                }
                return existing.provider
            }
            return nil
        }
        let fingerprint = Self.endpointFingerprint(profile) + (recent?.id.uuidString ?? "") + bound.value.schema
        if let existing = providers[worksheetID], existing.profile == fingerprint, existing.binding == bound.key { return existing.provider }
        let token = generation, revision = metadataRevision
        let provider = ProjectMetadataProvider(schema: bound.value.schema, databaseOID: bound.value.databaseOID)
        await provider.update(snapshot)
        guard token == generation, revision == metadataRevision, binding(for: profile)?.key == bound.key else {
            await provider.suspend()
            throw DatabaseError("The project changed while preparing query metadata. Run the query again.")
        }
        providers[worksheetID] = (fingerprint, bound.key, provider)
        return provider
    }
    func captureReview(_ candidate: ProjectConnectionCandidate) -> ProjectConnectionReview {
        .init(projectID: recent?.id, generation: generation, candidateID: candidate.id,
              fingerprint: candidate.nonsecretFingerprint, secretRevision: candidate.secretRevision)
    }
    @discardableResult func bind(profile: ConnectionProfile, key: String, schema: String, candidateID: String?, expectedReview: ProjectConnectionReview? = nil) async -> Bool {
        guard let recent, !key.isEmpty, !schema.isEmpty, !savingSettings else { return false }
        if let review = expectedReview {
            guard review.projectID == recent.id, review.generation == generation,
                  let current = configuration?.candidates.first(where: { $0.id == review.candidateID }),
                  current.nonsecretFingerprint == review.fingerprint, current.secretRevision == review.secretRevision else {
                error = "The connection was saved, but its project or source changed during review. Review the project binding again."
                return false
            }
        }
        let token = generation
        let candidate = configuration?.candidates.first { $0.id == candidateID }
        let binding = ProjectPrivateBinding(profileID: profile.id, endpointFingerprint: Self.endpointFingerprint(profile), schema: schema,
            candidateID: candidateID, candidateFingerprint: candidate?.nonsecretFingerprint)
        do {
            try await privateStore.bind(projectID: recent.id, key: key, binding: binding)
            guard token == generation else { return false }
            metadataRevision = UUID()
            bindings[key] = binding; reviewRequired.remove(key); changedCandidates[key] = nil
            acceptedSecrets[key] = candidate?.secretRevision
            mutateSettings { $0.bindings[key] = ProjectLogicalBinding(sourceGroup: candidate?.sourceGroup ?? "manual") }
            for item in providers.values where item.binding == key { await item.provider.suspend() }
            providers = providers.filter { $0.value.binding != key }
            didChange?(); return true
        } catch { self.error = "The project binding could not be saved."; return false }
    }
    func observeObjects(_ objects: [DatabaseObject]) {
        guard let first = objects.first, let bound = binding(for: first.id.source.profile), let recent else { return }
        if let oid = bound.value.databaseOID, oid != first.id.databaseOID {
            reviewRequired.insert(bound.key); changedCandidates[bound.key] = "Database identity changed; review this binding."; didChange?(); return
        }
        if bound.value.databaseOID == nil {
            var updated = bound.value; updated.databaseOID = first.id.databaseOID
            bindings[bound.key] = updated
            Task { try? await privateStore.bind(projectID: recent.id, key: bound.key, binding: updated) }
        }
    }
    func sourceModel(for object: DatabaseObject) -> ProjectModelMetadata? {
        guard let bound = binding(for: object.id.source.profile), object.schema.utf8.elementsEqual(bound.value.schema.utf8),
              let model = modelByTable[object.name], model.tableName?.utf8.elementsEqual(object.name.utf8) == true else { return nil }
        return model
    }
    func inspectModel(for object: DatabaseObject) {
        inspectedModel = sourceModel(for: object); showingDetails = inspectedModel != nil
    }
    func displayName(_ namespace: String) -> String {
        settings?.settings.namespaces.displayNames[namespace] ?? (namespace == "base" ? "Base" : namespace == "unclassified" ? "Unclassified" : namespace)
    }
    private func matchedOverride(_ object: DatabaseObject, binding: (key: String, value: ProjectPrivateBinding)) -> ProjectObjectOverride? {
        guard binding.value.objects.contains(where: { $0.schema == object.schema && $0.relation == object.name && $0.databaseOID == object.id.databaseOID && $0.schemaOID == object.schemaOID && $0.relationOID == object.id.relationOID && $0.identityToken == object.identityToken }) else { return nil }
        return settings?.settings.objectOverrides.first { $0.binding == binding.key && $0.schema == object.schema && $0.relation == object.name }
    }
    func namespace(for object: DatabaseObject) -> String {
        guard let bound = binding(for: object.id.source.profile), bound.value.schema == object.schema else { return "unclassified" }
        if let override = matchedOverride(object, binding: bound) { return override.namespace }
        if settings?.settings.objectOverrides.contains(where: { $0.binding == bound.key && $0.schema == object.schema && $0.relation == object.name }) == true { return "unclassified" }
        guard sourceModel(for: object) != nil else { return "unclassified" }
        return namespaceByTable[object.name] ?? "unclassified"
    }
    func groups(_ objects: [DatabaseObject]) -> [ProjectNamespaceGroup] {
        guard let profile = objects.first?.id.source.profile, let bound = binding(for: profile) else {
            return objects.isEmpty ? [] : [.init(id: "unclassified", title: "Unclassified", objects: objects)]
        }
        let overrides = Dictionary((settings?.settings.objectOverrides ?? []).filter { $0.binding == bound.key }.map {
            (CatalogMembership(schema: $0.schema, relation: $0.relation), $0.namespace)
        }, uniquingKeysWith: { first, _ in first })
        let anchors = Dictionary(bound.value.objects.map {
            (CatalogMembership(schema: $0.schema, relation: $0.relation), $0)
        }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: objects) { object -> String in
            let key = CatalogMembership(schema: object.schema, relation: object.name)
            if let override = overrides[key] {
                guard let anchor = anchors[key], anchor.databaseOID == object.id.databaseOID, anchor.schemaOID == object.schemaOID,
                      anchor.relationOID == object.id.relationOID, anchor.identityToken == object.identityToken else { return "unclassified" }
                return override
            }
            guard object.schema.utf8.elementsEqual(bound.value.schema.utf8),
                  modelByTable[object.name]?.tableName?.utf8.elementsEqual(object.name.utf8) == true else { return "unclassified" }
            return namespaceByTable[object.name] ?? "unclassified"
        }
        return (namespaceNames + ["unclassified"]).reduce(into: [ProjectNamespaceGroup]()) { result, key in
            guard !result.contains(where: { $0.id == key }), let values = groups[key], !values.isEmpty else { return }
            result.append(ProjectNamespaceGroup(id: key, title: displayName(key), objects: values))
        }
    }
    func catalogFilter(for profile: ConnectionProfile?) -> CatalogNamespaceFilter {
        guard let profile, let bound = binding(for: profile) else { return .init() }
        var memberships: [String: [CatalogMembership]] = [:]
        let overrides = settings?.settings.objectOverrides.filter { $0.binding == bound.key } ?? []
        // A stale override is never attached to a replacement table. Exact
        // identity predicates also prevent it from concealing a replacement.
        let overridden = Set(overrides.compactMap { item -> String? in
            guard bound.value.objects.contains(where: { $0.schema == item.schema && $0.relation == item.relation }) else { return nil }
            return item.schema == bound.value.schema ? item.relation : nil
        })
        for (table, namespace) in namespaceByTable where !overridden.contains(table) {
            memberships[namespace, default: []].append(.init(schema: bound.value.schema, relation: table))
        }
        for item in overrides {
            if let anchor = bound.value.objects.first(where: { $0.schema == item.schema && $0.relation == item.relation }) {
                memberships[item.namespace, default: []].append(.init(schema: item.schema, relation: item.relation, oid: anchor.relationOID, token: anchor.identityToken))
            }
        }
        if selectedNamespace == "unclassified" { return .init(excluded: memberships.values.flatMap { $0 }) }
        if let selectedNamespace { return .init(included: selectedNamespace == "base" && !showBase ? [] : memberships[selectedNamespace] ?? []) }
        return .init(excluded: showBase ? [] : memberships["base"] ?? [])
    }
    func assign(_ object: DatabaseObject, namespace: String) async {
        guard let bound = binding(for: object.id.source.profile), let recent,
              !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = generation
        var updated = bound.value
        updated.objects.removeAll { $0.schema == object.schema && $0.relation == object.name }
        updated.objects.append(ProjectPrivateObjectAnchor(schema: object.schema, relation: object.name, databaseOID: object.id.databaseOID,
            schemaOID: object.schemaOID, relationOID: object.id.relationOID, identityToken: object.identityToken))
        do {
            try await privateStore.bind(projectID: recent.id, key: bound.key, binding: updated)
            guard token == generation else { return }
            bindings[bound.key] = updated
            mutateSettings {
                $0.objectOverrides.removeAll { $0.binding == bound.key && $0.schema == object.schema && $0.relation == object.name }
                $0.objectOverrides.append(ProjectObjectOverride(binding: bound.key, schema: object.schema, relation: object.name, namespace: namespace))
            }
        } catch { self.error = "The object identity could not be saved. Namespace assignment was not changed." }
    }
    func setShowBase(_ value: Bool) { mutateSettings { $0.namespaces.showBase = value } }
    func setNamespace(_ key: String, displayName: String, position: Int) {
        mutateSettings {
            $0.namespaces.displayNames[key] = displayName
            $0.namespaces.order.removeAll { $0 == key }
            $0.namespaces.order.insert(key, at: min(max(0, position), $0.namespaces.order.count))
        }
    }
    private func mutateSettings(_ mutation: (inout ProjectSettings) -> Void) {
        guard var document = settings, !savingSettings else { settingsError = "Reload settings or wait for the current save before making another change."; return }
        mutation(&document.settings); settings = document; unsavedSettings = true; didChange?(); retrySettings()
    }
    func retrySettings() {
        guard let store = settingsStore, let document = settings, unsavedSettings, !savingSettings else { return }
        savingSettings = true; let token = generation
        Task {
            do {
                let saved = try await store.save(document, expectedDigest: document.digest)
                guard token == generation else { return }
                settings = saved; unsavedSettings = false; settingsError = nil
            } catch { guard token == generation else { return }; settingsError = "Changes not saved. " + error.localizedDescription }
            savingSettings = false; didChange?()
        }
    }
    func reloadSettings() {
        guard let store = settingsStore, !savingSettings else { return }
        let token = generation
        Task {
            do { let loaded = try await store.load(); guard token == generation else { return }; settings = loaded; unsavedSettings = false; settingsError = nil; metadataRevision = UUID(); didChange?() }
            catch { guard token == generation else { return }; settingsError = error.localizedDescription }
        }
    }
    func revealSettings() {
        guard let root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(".db3/project.json")])
    }
}
