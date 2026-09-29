import AppKit
import Foundation
import Observation
import DB3Core
import DB3Postgres
import DB3Projects

@MainActor @Observable
final class WorkbenchModel {
    static let maximumWorksheets = 4
    private(set) var worksheets: [Worksheet]
    var selectedID: UUID?
    var selectedBrowserProfileID: UUID? {
        didSet {
            guard selectedBrowserProfileID != oldValue else { return }
            objectBrowser.selectProfile(selectedBrowserProfile, load: false)
            if !isSynchronizingProject, catalogConnectionEditIntent != nil { dismissConnectionEditor() }
            synchronizeProject()
        }
    }
    var profiles: [ConnectionProfile] = [] {
        didSet {
            for sheet in worksheets {
                if let saved = profiles.first(where: { $0.id == sheet.profile?.id }) { sheet.restrictEnvironment(to: saved.environment) }
            }
            objectBrowser.synchronizeProfiles(profiles)
            if objectBrowser.selectedProfile == nil, let profile = selectedBrowserProfile {
                objectBrowser.selectProfile(profile, load: false)
            }
            synchronizeProject()
        }
    }
    let project: ProjectWorkspaceModel
    var projectConnectionCandidate: ProjectConnectionCandidate?
    @ObservationIgnored private var lastProjectMetadataRevision: UUID?
    @ObservationIgnored private var isSynchronizingProject = false
    let objectBrowser: ObjectBrowserModel
    var showingConnection = false
    var showingInspector = false
    var editingProfile: ConnectionProfile?
    private(set) var connectionEditTarget: ConnectionEditTarget?
    private(set) var catalogConnectionEditIntent: UUID?
    private var worksheetCredentialRequests: [WorksheetCredentialRequest] = []
    var worksheetCredentialRequest: WorksheetCredentialRequest? { worksheetCredentialRequests.first }
    var hasConnectionPrompt: Bool {
        showingConnection || worksheetCredentialRequest != nil || objectBrowser.credentialRequest != nil
    }
    var error: String?
    private(set) var isCoordinatingClose = false
    private(set) var isRestoringWorkspace = false
    private(set) var isPreservingWorkspace = false
    @ObservationIgnored let persistence: any WorkbenchPersistence
    @ObservationIgnored private let workspaceStore: any WorkspaceRecoveryPersistence
    @ObservationIgnored private let dialogs: any WorkbenchDialogs
    @ObservationIgnored private let worksheetFactory: @MainActor (String) -> Worksheet
    @ObservationIgnored private var nextUntitledNumber = 2
    @ObservationIgnored private var vacantWorksheet: Worksheet?
    @ObservationIgnored private var workspaceGeneration = UUID()
    @ObservationIgnored private var savingDestinations: [URL: UUID] = [:]
    @ObservationIgnored private var hasLoadedWorkspace = false

    // During window teardown SwiftUI can evaluate one last body after removal.
    // This disconnected sentinel is never shown in or admitted to the workspace.
    var active: Worksheet {
        if let sheet = worksheets.first(where: { $0.id == selectedID }) ?? worksheets.first { return sheet }
        if let vacantWorksheet { return vacantWorksheet }
        let sheet = worksheetFactory("No query"); vacantWorksheet = sheet; return sheet
    }
    var canAddWorksheet: Bool { worksheets.count < Self.maximumWorksheets && !isCoordinatingClose && !isRestoringWorkspace }
    var tabLimitMessage: String { "You can open up to four query tabs. Close a tab to open another." }
    var hasUnfinishedWork: Bool { worksheets.contains { $0.isDirty || $0.isBusy || $0.isSaving || $0.hasPendingGridWork || $0.transaction == .inTransaction || $0.transaction == .failed } }
    var visibleProfiles: [ConnectionProfile] {
        guard project.isOpen else { return profiles }
        let ids = project.connectionProfileIDs
        return profiles.filter { ids.contains($0.id) }
    }
    var selectedBrowserProfile: ConnectionProfile? { visibleProfiles.first { $0.id == selectedBrowserProfileID } }

    init(persistence: any WorkbenchPersistence = LocalPersistence(), dialogs: any WorkbenchDialogs = NativeWorkbenchDialogs(), catalogService: any CatalogService = PostgresCatalogService(), workspaceStore: (any WorkspaceRecoveryPersistence)? = nil, project: ProjectWorkspaceModel = ProjectWorkspaceModel(), worksheetFactory: @escaping @MainActor (String) -> Worksheet = { Worksheet(title: $0) }) {
        self.persistence = persistence; self.dialogs = dialogs; self.worksheetFactory = worksheetFactory
        self.project = project
        self.workspaceStore = workspaceStore ?? (persistence as? any WorkspaceRecoveryPersistence) ?? MemoryWorkspaceRecoveryStore()
        objectBrowser = ObjectBrowserModel(service: catalogService, credentials: { id in try await persistence.password(for: id) })
        let sheet = worksheetFactory("Query 1"); worksheets = [sheet]; selectedID = sheet.id
        installProjectResolver(sheet)
        project.didChange = { [weak self] in self?.synchronizeProject() }
        objectBrowser.didLoadObjects = { [weak self] objects in self?.project.observeObjects(objects) }
    }
    func load() async {
        guard !hasLoadedWorkspace, !isRestoringWorkspace, !isCoordinatingClose else { return }
        isRestoringWorkspace = true
        defer { isRestoringWorkspace = false }
        let generation = workspaceGeneration
        let originalTabs = worksheets.map { ($0.id, $0.documentRevision) }
        do {
            let savedProfiles = try await persistence.loadProfiles()
            guard generation == workspaceGeneration else { return }
            profiles = savedProfiles
        } catch { self.error = "Could not load connection profiles: \(error.localizedDescription)" }
        do {
            let snapshot = try await workspaceStore.loadWorkspace()
            guard generation == workspaceGeneration, !Task.isCancelled else { return }
            hasLoadedWorkspace = true
            guard let snapshot, !snapshot.tabs.isEmpty else { return }
            guard worksheets.count == originalTabs.count,
                  zip(worksheets, originalTabs).allSatisfy({ $0.0.id == $0.1.0 && $0.0.documentRevision == $0.1.1 && !$0.0.isConnected && !$0.0.isBusy }) else {
                error = "The current workspace changed while recovery was loading. Your current queries were kept."
                return
            }
            let oldSheets = worksheets
            worksheets = snapshot.tabs.map { tab in
                let sheet = worksheetFactory(tab.title)
                sheet.restoreWorkspace(tab)
                installProjectResolver(sheet)
                return sheet
            }
            selectedID = worksheets[snapshot.selectedTabIndex].id
            selectedBrowserProfileID = snapshot.selectedBrowserProfileID
            showingInspector = snapshot.showingInspector
            nextUntitledNumber = snapshot.nextUntitledNumber
            for sheet in oldSheets { await sheet.close() }
        } catch { self.error = "Could not restore the workspace: \(error.localizedDescription)" }
    }
    func worksheet(id: UUID) -> Worksheet? { worksheets.first { $0.id == id && !$0.isClosed } }
    func selectBrowserProfile(_ profile: ConnectionProfile) {
        loadCatalogConnection(profile)
    }
    func loadCatalogConnection(_ profile: ConnectionProfile, password: String? = nil) {
        guard visibleProfiles.contains(profile), !isCoordinatingClose else { return }
        selectedBrowserProfileID = profile.id
        objectBrowser.selectProfile(profile, load: false)
        synchronizeProject()
        if let password { objectBrowser.load(password: password) }
        else { objectBrowser.load() }
    }
    func openSelectedObjectQuery() {
        guard let selection = objectBrowser.captureSelection() else { return }
        guard let sheet = openQueryTab(context: QueryOpeningContext(profile: selection.profile, database: selection.database.name,
            schema: selection.object.schema, object: selection.object.name),
            sql: selection.object.selectSQL, title: selection.object.qualifiedName) else { return }
        connectObjectWorksheet(sheet, selection: selection)
    }
    func openSelectedObjectForEditing() {
        guard let selection = objectBrowser.captureSelection() else { return }
        guard selection.object.kind == .table, !selection.object.isPartition, !selection.object.isPartitioned else {
            error = "Editing requires an ordinary table with a primary key. Views and partitioned tables remain read-only."
            return
        }
        let target = WorksheetEditTarget(relationOID: selection.object.id.relationOID,
            schema: selection.object.schema, name: selection.object.name)
        guard let sheet = openQueryTab(context: QueryOpeningContext(profile: selection.profile, database: selection.database.name,
            schema: target.schema, object: target.name), sql: target.initialSQL, title: target.schema + "." + target.name + " · Edit") else { return }
        sheet.editTarget = target
        sheet.ownedEditSQL = target.initialSQL
        connectObjectWorksheet(sheet, selection: selection)
    }
    private func connectObjectWorksheet(_ sheet: Worksheet, selection: ObjectQuerySelection) {
        guard let profile = sheet.profile else { return }
        connectSaved(profile, in: sheet, password: objectBrowser.password(for: selection))
    }
    func openBaseTableForEditing(_ sheet: Worksheet, relationOID: UInt32) {
        guard canAddWorksheet, sheet.canIssueCommands, !sheet.isBusy, let profile = sheet.profile,
              let coordinator = sheet.managedSession else { return }
        let token = UUID(); sheet.generation = token; sheet.isBusy = true
        sheet.operation = Task {
            defer { if sheet.generation == token { sheet.isBusy = false; sheet.operation = nil } }
            do {
                let table = try await coordinator.withExclusiveOperation { session in
                    try await PostgresTableEditing.describe(relationOID: relationOID, on: session)
                }
                guard sheet.generation == token, !sheet.isClosing, !sheet.isClosed else { return }
                if let reason = table.readOnlyReason { throw DatabaseError(reason) }
                let target = WorksheetEditTarget(relationOID: table.relationOID, schema: table.schema, name: table.name)
                guard let editing = openQueryTab(context: QueryOpeningContext(profile: profile, schema: table.schema, object: table.name),
                    sql: table.selectSQL(), title: table.schema + "." + table.name + " · Edit") else { return }
                editing.editTarget = target; editing.ownedEditSQL = editing.sql
                connectSaved(profile, in: editing)
            } catch { if sheet.generation == token { self.error = error.localizedDescription } }
        }
    }
    func selectTab(_ id: UUID) { guard worksheet(id: id) != nil else { return }; selectedID = id }
    func selectTab(at index: Int) {
        guard worksheets.indices.contains(index) else { return }
        selectTab(worksheets[index].id)
    }
    func selectAdjacentTab(_ offset: Int) {
        guard !worksheets.isEmpty else { return }
        let index = worksheets.firstIndex { $0.id == selectedID } ?? 0
        selectedID = worksheets[((index + offset) % worksheets.count + worksheets.count) % worksheets.count].id
    }
    func moveTab(_ id: UUID, by offset: Int) {
        guard let index = worksheets.firstIndex(where: { $0.id == id }), worksheets.indices.contains(index + offset) else { return }
        let sheet = worksheets.remove(at: index); worksheets.insert(sheet, at: index + offset)
    }
    func reorderTab(_ id: UUID, before target: UUID) {
        guard id != target, let source = worksheets.firstIndex(where: { $0.id == id }), worksheets.contains(where: { $0.id == target }) else { return }
        let sheet = worksheets.remove(at: source)
        let destination = worksheets.firstIndex { $0.id == target }!
        worksheets.insert(sheet, at: destination)
    }
    func renameTab(_ id: UUID, to title: String) {
        guard let sheet = worksheet(id: id), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sheet.title = title
    }
    private func preferredContext() -> QueryOpeningContext {
        let current = worksheets.first(where: { $0.id == selectedID })?.profile
        let fallback = !project.isOpen || visibleProfiles.contains(where: { $0.id == current?.id }) ? current : nil
        return QueryOpeningContext(profile: selectedBrowserProfile ?? fallback)
    }
    @discardableResult private func createWorksheet(context: QueryOpeningContext, title: String? = nil) -> Worksheet? {
        guard canAddWorksheet else { error = tabLimitMessage; return nil }
        let label: String
        if let title { label = title }
        else { label = allocateUntitledName() }
        let sheet = worksheetFactory(label); sheet.profile = context.profile; sheet.queryContext = context
        installProjectResolver(sheet)
        worksheets.append(sheet); selectedID = sheet.id; return sheet
    }
    private func allocateUntitledName() -> String {
        while worksheets.contains(where: { $0.title == "Query \(nextUntitledNumber)" }) { nextUntitledNumber += 1 }
        let title = "Query \(nextUntitledNumber)"; nextUntitledNumber += 1; return title
    }
    func addWorksheet() { _ = createWorksheet(context: preferredContext()) }
    func addWorksheet(profile: ConnectionProfile) { _ = createWorksheet(context: QueryOpeningContext(profile: profile)) }
    @discardableResult func openQueryTab(context: QueryOpeningContext, sql: String, title: String? = nil) -> Worksheet? {
        guard let sheet = createWorksheet(context: context, title: title) else { return nil }
        sheet.setGeneratedSQL(sql); return sheet
    }
    func ensureWorkspace() {
        guard worksheets.isEmpty, !isCoordinatingClose else { return }
        _ = createWorksheet(context: QueryOpeningContext(profile: nil))
    }

    func reviewProjectCandidate(_ candidate: ProjectConnectionCandidate) {
        guard candidate.kind == .postgresql else { return }
        project.showingDetails = false
        editBrowserConnection(candidate.reviewProfile())
        if showingConnection { projectConnectionCandidate = candidate }
    }
    private func installProjectResolver(_ sheet: Worksheet) {
        sheet.resolveProjectEnvironment = { [weak self] profile in self?.project.policyRestriction(for: profile) }
        sheet.releaseProjectMetadata = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            await self.project.releaseProvider(worksheetID: sheet.id)
        }
        sheet.resolveProjectMetadata = { [weak self, weak sheet] in
            guard let self, let sheet, let profile = sheet.profile else { return nil }
            if let restriction = self.project.policyRestriction(for: profile) { sheet.restrictEnvironment(to: restriction) }
            return try await self.project.provider(for: profile, worksheetID: sheet.id)
        }
    }
    func synchronizeProject() {
        guard !isSynchronizingProject else { return }
        isSynchronizingProject = true
        defer { isSynchronizingProject = false }
        // Scope navigation without opening a session or retargeting existing tabs.
        let available = visibleProfiles
        let selected = available.first { $0.id == selectedBrowserProfileID }
            ?? (project.isOpen ? available.first : nil)
        if selectedBrowserProfileID != selected?.id { selectedBrowserProfileID = selected?.id }
        if objectBrowser.selectedProfile != selected { objectBrowser.selectProfile(selected, load: false) }
        let metadataChanged = lastProjectMetadataRevision != project.metadataRevision
        lastProjectMetadataRevision = project.metadataRevision
        objectBrowser.namespaceFilter = project.catalogFilter(for: objectBrowser.selectedProfile)
        for sheet in worksheets {
            if let profile = sheet.profile, let restriction = project.policyRestriction(for: profile) { sheet.restrictEnvironment(to: restriction) }
            if metadataChanged, sheet.metadataProvider != nil {
                sheet.projectMutationFence.invalidate()
                if sheet.isApplyingEdits { sheet.operation?.cancel() }
                sheet.invalidateEditableSnapshot()
            }
        }
    }

    func newConnection() { presentConnectionEditor(profile: nil, in: active) }
    func newConnection(in sheet: Worksheet) { presentConnectionEditor(profile: nil, in: sheet) }
    func editConnection(_ profile: ConnectionProfile) { presentConnectionEditor(profile: profile, in: active) }
    func editConnection(_ profile: ConnectionProfile, in sheet: Worksheet) { presentConnectionEditor(profile: profile, in: sheet) }
    /// Sidebar settings belong to the browser; editing them never reconnects a query.
    func editBrowserConnection(_ profile: ConnectionProfile) {
        guard !showingConnection, !isCoordinatingClose else { return }
        dismissWorksheetCredentialRequests()
        if objectBrowser.isBusy || objectBrowser.credentialRequest != nil { objectBrowser.cancel() }
        connectionEditTarget = nil; catalogConnectionEditIntent = UUID()
        projectConnectionCandidate = nil
        editingProfile = profile; showingConnection = true
    }
    private func presentConnectionEditor(profile: ConnectionProfile?, in sheet: Worksheet) {
        dismissWorksheetCredentialRequests(for: sheet.id)
        guard worksheet(id: sheet.id) === sheet, let intent = sheet.beginConnectionIntent() else {
            error = "Finish the active query or transaction before changing connections."; return
        }
        projectConnectionCandidate = nil
        catalogConnectionEditIntent = nil
        connectionEditTarget = ConnectionEditTarget(worksheetID: sheet.id, intent: intent)
        editingProfile = profile; showingConnection = true
    }
    func dismissConnectionEditor() {
        if let target = connectionEditTarget, let sheet = worksheet(id: target.worksheetID), sheet.connectionIntent == target.intent { sheet.invalidateConnectionIntent() }
        connectionEditTarget = nil; catalogConnectionEditIntent = nil; showingConnection = false
        projectConnectionCandidate = nil
    }
    func connectWorksheet(_ sheet: Worksheet) {
        if sheet.isDemo, let profile = sheet.profile, let intent = sheet.beginConnectionIntent() {
            sheet.connect(profile, password: "", demo: true, intent: intent)
        } else if let profile = sheet.profile { connectSaved(profile, in: sheet) }
        else { newConnection(in: sheet) }
    }
    func connectSaved(_ profile: ConnectionProfile) { connectSaved(profile, in: active) }
    func connectSaved(_ profile: ConnectionProfile, in sheet: Worksheet, password: String? = nil) {
        dismissWorksheetCredentialRequests(for: sheet.id)
        guard worksheet(id: sheet.id) === sheet, let intent = sheet.beginConnectionIntent() else {
            error = "Finish the active query or transaction before changing connections."; return
        }
        let id = sheet.id
        Task {
            do {
                let credential: String
                if let password { credential = password }
                else { credential = try await persistence.password(for: profile.id) }
                guard let target = worksheet(id: id), target === sheet, target.acceptsConnectionIntent(intent) else { return }
                target.connect(profile, password: credential, intent: intent)
                if let saved = profiles.first(where: { $0.id == profile.id }) { target.restrictEnvironment(to: saved.environment) }
            } catch {
                guard let target = worksheet(id: id), target === sheet, target.acceptsConnectionIntent(intent),
                      !isCoordinatingClose, !isRestoringWorkspace, !Task.isCancelled else { return }
                worksheetCredentialRequests.append(WorksheetCredentialRequest(profile: profile,
                    target: ConnectionEditTarget(worksheetID: id, intent: intent)))
            }
        }
    }
    func submitWorksheetPassword(_ password: String, for requestID: UUID) {
        guard let request = worksheetCredentialRequest, request.id == requestID else { return }
        worksheetCredentialRequests.removeFirst()
        guard !isCoordinatingClose, let sheet = worksheet(id: request.target.worksheetID),
              sheet.acceptsConnectionIntent(request.target.intent) else { return }
        // Do not save profiles, reread Keychain, or delete its inaccessible item.
        sheet.connect(request.profile, password: password, intent: request.target.intent)
        if let saved = profiles.first(where: { $0.id == request.profile.id }) { sheet.restrictEnvironment(to: saved.environment) }
    }
    func dismissWorksheetCredentialRequest(_ requestID: UUID) {
        guard let index = worksheetCredentialRequests.firstIndex(where: { $0.id == requestID }) else { return }
        let request = worksheetCredentialRequests.remove(at: index)
        if let sheet = worksheet(id: request.target.worksheetID), sheet.connectionIntent == request.target.intent {
            sheet.invalidateConnectionIntent()
        }
    }
    private func dismissWorksheetCredentialRequests(for worksheetID: UUID? = nil) {
        for request in worksheetCredentialRequests where worksheetID == nil || request.target.worksheetID == worksheetID {
            dismissWorksheetCredentialRequest(request.id)
        }
    }
    func saveAndConnect(profile: ConnectionProfile, password: String, remember: Bool, target: ConnectionEditTarget? = nil) async throws {
        guard let target = target ?? connectionEditTarget, let sheet = worksheet(id: target.worksheetID), sheet.acceptsConnectionIntent(target.intent) else {
            throw DatabaseError("The target query has closed or a newer connection action replaced this one.")
        }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile } else { updated.append(profile) }
        try await persistence.savePassword(remember ? password : "", for: profile.id)
        try await persistence.saveProfiles(updated)
        objectBrowser.invalidateCredentials(profileID: profile.id)
        profiles = updated
        guard worksheet(id: sheet.id) === sheet, sheet.acceptsConnectionIntent(target.intent) else { return }
        sheet.connect(profile, password: password, intent: target.intent)
    }
    func saveCatalogConnection(profile: ConnectionProfile, password: String, remember: Bool, intent: UUID, loadObjects: Bool = true) async throws {
        guard catalogConnectionEditIntent == intent else { throw DatabaseError("This connection editor is no longer active.") }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        try await persistence.savePassword(remember ? password : "", for: profile.id)
        try await persistence.saveProfiles(updated)
        objectBrowser.invalidateCredentials(profileID: profile.id)
        profiles = updated
        guard catalogConnectionEditIntent == intent else { return }
        // Candidate review can finish its project binding before explicitly loading.
        catalogConnectionEditIntent = nil
        if loadObjects { loadCatalogConnection(profile, password: password) }
    }
    func sample() { sample(in: active) }
    func sample(in sheet: Worksheet) {
        guard worksheet(id: sheet.id) === sheet, sheet.canIssueCommands else { return }
        let target: Worksheet
        if sheet.isDirty {
            guard let created = createWorksheet(context: QueryOpeningContext(profile: nil)) else { return }
            target = created
        } else { target = sheet }
        guard let intent = target.beginConnectionIntent() else { return }
        target.setGeneratedSQL("-- Sample workspace · generated locally, no PostgreSQL server\n-- Press Run to inspect 10,000 sample rows.\nSELECT * FROM sample_customers;")
        target.connect(ConnectionProfile(name: "Sample workspace"), password: "", demo: true, intent: intent)
    }

    func requestClose(_ sheet: Worksheet) {
        let id = sheet.id
        Task { _ = await closeTabs(ids: [id], replacingLastTab: true) }
    }
    @discardableResult func closeTab(id: UUID) async -> Bool { await closeTabs(ids: [id], replacingLastTab: true) }
    @discardableResult func requestCloseWorkspace() async -> Bool {
        guard !project.unsavedSettings, !project.savingSettings else {
            project.showingDetails = true
            error = "Project settings have unsaved changes. Retry saving or reload the settings before quitting."
            return false
        }
        guard await closeTabs(ids: worksheets.map(\.id), replacingLastTab: false, preservingWorkspace: true) else { return false }
        isCoordinatingClose = true
        defer { isCoordinatingClose = false }
        await objectBrowser.shutdown()
        await project.shutdown()
        hasLoadedWorkspace = false
        return true
    }
    private func closeTabs(ids: [UUID], replacingLastTab: Bool, preservingWorkspace: Bool = false) async -> Bool {
        guard !isCoordinatingClose, !isRestoringWorkspace else { return false }
        let targets = ids.compactMap { worksheet(id: $0) }
        guard !targets.isEmpty else { return true }
        isCoordinatingClose = true
        isPreservingWorkspace = preservingWorkspace
        targets.forEach { $0.isClosePending = true }
        defer {
            targets.forEach { $0.isClosePending = false }
            isCoordinatingClose = false
            isPreservingWorkspace = false
        }
        // Decisions are gathered before stopping or removing ANY session. If an
        // earlier document changes while a later alert is open, restart review.
        review: while !Task.isCancelled {
            var approved: [UUID: WorksheetCloseSnapshot] = [:]
            for sheet in targets {
                guard worksheet(id: sheet.id) === sheet, !sheet.isClosed else { return false }
                if sheet.isSaving || (preservingWorkspace && sheet.isLoading) { error = "Wait for “\(sheet.title)” to finish loading or saving before closing it."; return false }
                let snapshot = WorksheetCloseSnapshot(sheet, preservingDraft: preservingWorkspace)
                if snapshot.needsDecision {
                    let decision = await dialogs.confirmClose(snapshot)
                    guard decision != .keepOpen else { return false }
                    if decision == .reviewGrid {
                        selectedID = sheet.id
                        DispatchQueue.main.async { sheet.previewChanges() }
                        return false
                    }
                    guard WorksheetCloseSnapshot(sheet, preservingDraft: preservingWorkspace) == snapshot else { continue review }
                    if decision == .save && !preservingWorkspace {
                        let content = sheet.sql
                        guard await saveSQL(sheet: sheet) else { return false }
                        guard sheet.sql == content, sheet.documentRevision == snapshot.documentRevision else { continue review }
                        // Session completion may change the consequences during a save.
                        let after = WorksheetCloseSnapshot(sheet)
                        guard after.isBusy == snapshot.isBusy, after.transaction == snapshot.transaction, after.activityGeneration == snapshot.activityGeneration else { continue review }
                    }
                }
                approved[sheet.id] = WorksheetCloseSnapshot(sheet, preservingDraft: preservingWorkspace)
            }
            guard targets.allSatisfy({ approved[$0.id] == WorksheetCloseSnapshot($0, preservingDraft: preservingWorkspace) }) else { continue }
            guard !Task.isCancelled else { return false }
            if preservingWorkspace {
                let recovery = workspaceSnapshot()
                do {
                    try await workspaceStore.saveWorkspace(recovery)
                } catch {
                    self.error = "Could not preserve the workspace. Your tabs remain open: \(error.localizedDescription)"
                    return false
                }
                guard !Task.isCancelled else { return false }
                // A running query can finish or fail while the draft is written.
                // Recheck transaction consequences before any session is closed.
                guard targets.allSatisfy({ approved[$0.id] == WorksheetCloseSnapshot($0, preservingDraft: true) }) else { continue }
                guard recovery == workspaceSnapshot() else { continue }
            }
            if !replacingLastTab { workspaceGeneration = UUID() }
            for sheet in targets { dismissWorksheetCredentialRequests(for: sheet.id) }
            targets.forEach { $0.prepareToClose() }
            for sheet in targets { await sheet.close() }
            // The user may select/reorder another tab while shutdown awaits.
            // Derive adjacency and selection from the current order at removal.
            let selectedBefore = selectedID
            let selectedIndex = worksheets.firstIndex { $0.id == selectedBefore }
            let closedIDs = Set(targets.map(\.id))
            let remaining = worksheets.filter { !closedIDs.contains($0.id) }
            let replacementID: UUID?
            if let selectedIndex, let selectedBefore, closedIDs.contains(selectedBefore) {
                replacementID = worksheets.dropFirst(selectedIndex + 1).first(where: { !closedIDs.contains($0.id) })?.id
                    ?? worksheets.prefix(selectedIndex).last(where: { !closedIDs.contains($0.id) })?.id
            } else { replacementID = selectedBefore }
            worksheets = remaining; selectedID = replacementID
            if worksheets.isEmpty, replacingLastTab {
                let replacement = worksheetFactory(allocateUntitledName())
                worksheets = [replacement]; selectedID = replacement.id
            }
            return true
        }
        return false
    }
    /// Only use after a coordinated approval, or in headless teardown.
    func shutdown() async {
        dismissWorksheetCredentialRequests()
        for sheet in worksheets { sheet.prepareToClose() }
        await objectBrowser.shutdown()
        for sheet in worksheets { await sheet.close() }
    }

    private func workspaceSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(tabs: worksheets.map { $0.workspaceSnapshot() },
            selectedTabIndex: worksheets.firstIndex(where: { $0.id == selectedID }) ?? 0,
            selectedBrowserProfileID: selectedBrowserProfileID, showingInspector: showingInspector,
            nextUntitledNumber: nextUntitledNumber)
    }

    func openSQL() {
        let context = preferredContext(); let generation = workspaceGeneration
        Task {
            guard let url = await dialogs.chooseOpenSQL(), generation == workspaceGeneration else { return }
            _ = await openSQL(at: url, context: context)
        }
    }
    @discardableResult func openSQL(at url: URL, context: QueryOpeningContext? = nil) async -> Worksheet? {
        let openingContext = context ?? preferredContext()
        let generation = workspaceGeneration
        let identity = await SQLFileIdentityResolver.shared.resolve(url)
        guard generation == workspaceGeneration, !isCoordinatingClose, !Task.isCancelled else { return nil }
        if let savingID = savingDestinations[identity], let existing = worksheet(id: savingID) {
            selectTab(existing.id); return existing
        }
        if let existing = worksheets.first(where: { $0.fileURL == identity }) {
            selectTab(existing.id); return existing
        }
        guard let sheet = createWorksheet(context: openingContext, title: url.lastPathComponent) else { return nil }
        let token = sheet.beginLoading(from: identity); let revision = sheet.documentRevision
        do {
            let content = try await persistence.readSQL(at: identity)
            guard worksheet(id: sheet.id) === sheet else { return nil }
            if !sheet.completeLoading(content, token: token, revision: revision), !sheet.isClosing {
                sheet.failLoading(DatabaseError("The document changed while loading; its current text was preserved."), token: token)
            }
        } catch {
            guard worksheet(id: sheet.id) === sheet, !sheet.isClosing else { return nil }
            sheet.failLoading(error, token: token); self.error = error.localizedDescription
        }
        return sheet
    }
    func saveSQL() { let sheet = active; Task { _ = await saveSQL(sheet: sheet) } }
    @discardableResult func saveSQL(sheet: Worksheet, to explicitURL: URL? = nil, saveAs: Bool = false) async -> Bool {
        guard worksheet(id: sheet.id) === sheet, sheet.beginSaving() else { return false }
        defer { sheet.finishSaving() }
        let content = sheet.sql; let generation = workspaceGeneration
        let url: URL?
        if let explicitURL { url = explicitURL }
        else if let existing = sheet.fileURL, !saveAs { url = existing }
        else { url = await dialogs.chooseSaveSQL(title: sheet.title, currentURL: sheet.fileURL) }
        guard let url, worksheet(id: sheet.id) === sheet, !sheet.isClosing else { return false }
        let identity = await SQLFileIdentityResolver.shared.resolve(url)
        guard generation == workspaceGeneration, worksheet(id: sheet.id) === sheet,
              !sheet.isClosed, !sheet.isClosing, sheet.isSaving, !Task.isCancelled else { return false }
        guard savingDestinations[identity] == nil,
              !worksheets.contains(where: { $0.id != sheet.id && $0.fileURL == identity }) else {
            error = "That SQL file is already open in another query tab."; return false
        }
        savingDestinations[identity] = sheet.id
        defer { savingDestinations[identity] = nil }
        do {
            try await persistence.writeSQL(content, at: identity)
            guard worksheet(id: sheet.id) === sheet, !sheet.isClosing else { return false }
            sheet.didSave(content, to: identity); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func exportCSV() { exportCSV(sheet: active) }
    func exportCSV(sheet: Worksheet) {
        let id = sheet.id
        let resultRevision = sheet.revision
        Task {
            guard let url = await dialogs.chooseExportCSV(), let target = worksheet(id: id), target === sheet, target.canIssueCommands else { return }
            guard target.revision == resultRevision else {
                error = "The query results changed while choosing an export file. Start Export CSV again for the current results."
                return
            }
            target.exportCSV(to: url)
        }
    }
}
