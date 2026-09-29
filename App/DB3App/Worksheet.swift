import Foundation
import Observation
import OSLog
import DB3Core
import DB3Postgres
import DB3Results
import DB3Grid

private let events = Logger(subsystem: "app.db3", category: "query")
private let signposter = OSSignposter(logger: events)
private let spoolBudget = ResultStore.SpoolBudget(byteLimit: 1_024 * 1_024 * 1_024)

private actor ProgressRelay {
    private var last = ContinuousClock.now
    private var isFirst = true
    func shouldPublish() -> Bool {
        if isFirst { isFirst = false; signposter.emitEvent("FirstStoredBatch"); return true }
        let now = ContinuousClock.now
        guard last.duration(to: now) >= .milliseconds(50) else { return false }
        last = now; return true
    }
}

@MainActor @Observable
final class Worksheet: Identifiable {
    let id = UUID()
    var title: String
    static let starterSQL = "-- Write a query, or select a statement to run.\nSELECT current_database(), current_user, version();"
    var sql = Worksheet.starterSQL {
        didSet { if oldValue != sql { documentRevision &+= 1 } }
    }
    private(set) var documentRevision: UInt64 = 0
    private(set) var savedSQL = Worksheet.starterSQL
    private(set) var fileURL: URL?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var loadGeneration = UUID()
    var isDirty: Bool { sql != savedSQL }
    var resultTab = 0
    var inspectorSelection = NSRange(location: 0, length: 0)
    var queryContext: QueryOpeningContext?
    var isClosePending = false
    private(set) var isClosing = false
    var canIssueCommands: Bool { !isClosed && !isClosing && !isLoading && !isClosePending }
    private(set) var connectionIntent = UUID()
    var selection = NSRange(location: 0, length: 0)
    var profile: ConnectionProfile?
    var columns: [DatabaseColumn] = []
    var rowCount = 0
    var revision = 0
    var status = "Not connected"
    var message = "Connect to PostgreSQL to start a worksheet."
    var isBusy = false
    var isConnected = false
    var isCancelling = false
    var isDemo = false
    var transaction: TransactionState = .unknown
    var commitMode: CommitMode = .manual
    var transactionStartedAt: Date?
    var transactionEpoch: UInt64 = 0
    var sessionIdentity = UUID()
    var pendingEnvironmentRestriction: ConnectionEnvironment = .unknown
    var editTarget: WorksheetEditTarget?
    var ownedEditSQL: String?
    var editableTable: EditableTable?
    var editProjection: ResultEditProjection?
    var queryEditReadOnlyReason: String?
    var editExpressionsNeedRefresh = false
    var editContext: EditSourceContext?
    var editBaselineValid = false
    var draftRows: [EditRowDraft] = []
    var insertRows: [InsertRowDraft] = []
    var draftRevision: UInt64 = 0
    var canUndoDraft = false
    var canRedoDraft = false
    var editPresentationRevision = 0
    var hasActiveCellEditor = false
    var previewPlan: EditPlan?
    var lookup: ForeignKeyLookupModel?
    var editConflict: EditConflict?
    var showingConflict = false
    var computedAcknowledgements: [Int: String] = [:]
    @ObservationIgnored var draftStore: EditDraftStore?
    @ObservationIgnored let cellEditor = ResultsGridEditorController()
    @ObservationIgnored let projectMutationFence = ProjectMutationFence()
    @ObservationIgnored var isApplyingEdits = false
    @ObservationIgnored var releaseProjectMetadata: (@MainActor () async -> Void)?
    @ObservationIgnored var resolveProjectEnvironment: (@MainActor (ConnectionProfile) -> ConnectionEnvironment?)?
    @ObservationIgnored var resolveProjectMetadata: (@MainActor () async throws -> (any FieldEditorMetadataProvider)?)?
    @ObservationIgnored var metadataProvider: (any FieldEditorMetadataProvider)?
    @ObservationIgnored var managedSession: ManagedSession?
    @ObservationIgnored var verifiedEditRow: EditableRowSnapshot?
    @ObservationIgnored var verifiedEditReservation: EditPayloadReservation?
    var serverVersion = ""
    var elapsed: TimeInterval = 0
    var selectedValue: String? {
        didSet { if oldValue != selectedValue { inspectorSelection = NSRange(location: 0, length: 0) } }
    }
    var selectedColumn: String?
    var error: String?
    var resultIncomplete = false
    var allowsSpooling = true
    private(set) var isClosed = false
    // Four worksheet slots divide the application budget rather than multiplying it.
    @ObservationIgnored var store = Worksheet.makeStore(allowsSpooling: true)
    @ObservationIgnored var session: any DatabaseSession
    @ObservationIgnored private let sessionFactory: @Sendable (Bool) -> any DatabaseSession
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored var operation: Task<Void, Never>?
    @ObservationIgnored var generation = UUID()

    init(title: String = "Query 1", sessionFactory: @escaping @Sendable (Bool) -> any DatabaseSession = { demo in
        if demo { return DemoSession() }
        return PostgresSession()
    }) {
        self.title = title
        self.sessionFactory = sessionFactory
        self.session = sessionFactory(false)
    }

    func setGeneratedSQL(_ text: String) { savedSQL = ""; sql = text; selection = NSRange(location: 0, length: 0) }
    func workspaceSnapshot() -> WorkspaceTabSnapshot {
        WorkspaceTabSnapshot(title: title, sql: sql, savedSQL: savedSQL, fileURL: fileURL,
            selectionLocation: selection.location, selectionLength: selection.length, profile: profile,
            database: queryContext?.database, schema: queryContext?.schema, object: queryContext?.object,
            allowsSpooling: allowsSpooling, resultTab: resultTab, isDemo: isDemo)
    }
    func restoreWorkspace(_ snapshot: WorkspaceTabSnapshot) {
        title = snapshot.title; sql = snapshot.sql; savedSQL = snapshot.savedSQL; fileURL = snapshot.fileURL
        selection = NSRange(location: snapshot.selectionLocation, length: snapshot.selectionLength)
        profile = snapshot.profile; allowsSpooling = snapshot.allowsSpooling; resultTab = snapshot.resultTab
        isDemo = snapshot.isDemo
        queryContext = QueryOpeningContext(profile: snapshot.profile, database: snapshot.database,
            schema: snapshot.schema, object: snapshot.object)
        status = "Restored · Not connected"
        message = "Your SQL was restored. Connect when you're ready; previous results and database transactions are not restored."
    }
    func beginLoading(from url: URL) -> UUID {
        loadGeneration = UUID(); isLoading = true; fileURL = url
        sql = ""; savedSQL = ""; selection = NSRange(location: 0, length: 0); status = "Loading SQL…"
        return loadGeneration
    }
    func completeLoading(_ text: String, token: UUID, revision: UInt64) -> Bool {
        guard token == loadGeneration, documentRevision == revision, !isClosed, !isClosing else { return false }
        sql = text; savedSQL = text; isLoading = false; status = "Not connected"
        return true
    }
    func failLoading(_ failure: Error, token: UUID) {
        guard token == loadGeneration, !isClosed, !isClosing else { return }
        isLoading = false; fileURL = nil; error = failure.localizedDescription; status = "Unable to open SQL"
    }
    func beginSaving() -> Bool {
        guard !isClosed, !isClosing, !isLoading, !isSaving else { return false }
        isSaving = true; return true
    }
    func finishSaving() { isSaving = false }
    func didSave(_ text: String, to url: URL) {
        guard !isClosed, !isClosing else { return }
        savedSQL = text; fileURL = url; title = url.lastPathComponent
    }
    /// Allocate before any Keychain read or modal edit. A later intent supersedes this one.
    func beginConnectionIntent() -> UUID? {
        guard canIssueCommands, !isBusy, !hasPendingGridWork, transaction != .inTransaction, transaction != .failed else { return nil }
        connectionIntent = UUID(); return connectionIntent
    }
    func acceptsConnectionIntent(_ token: UUID) -> Bool { canIssueCommands && connectionIntent == token && !isBusy && !hasPendingGridWork && transaction != .inTransaction && transaction != .failed }
    func invalidateConnectionIntent() { connectionIntent = UUID() }
    var activityGeneration: UUID { generation }
    static func makeStore(allowsSpooling: Bool) -> ResultStore {
        ResultStore(configuration: .init(residentByteLimit: 16 * 1_024 * 1_024, spoolByteLimit: 1_024 * 1_024 * 1_024, sharedSpoolBudget: spoolBudget, allowsSpooling: allowsSpooling, maximumBatchBytes: 2 * 1_024 * 1_024))
    }

    func connect(_ profile: ConnectionProfile, password: String, demo: Bool = false, intent: UUID? = nil) {
        guard canIssueCommands, !isBusy else { return }
        guard !hasPendingGridWork else { error = "Preview and apply or discard grid drafts before changing connections."; return }
        if let intent { guard acceptsConnectionIntent(intent) else { return } }
        else { invalidateConnectionIntent() }
        guard transaction != .inTransaction, transaction != .failed else { error = "Commit or roll back before changing connections."; return }
        let token = UUID(); generation = token
        if queryContext?.profile != profile || queryContext?.database != profile.database {
            queryContext = QueryOpeningContext(profile: profile)
        }
        isBusy = true; error = nil; status = "Connecting…"; self.profile = profile
        pendingEnvironmentRestriction = resolveProjectEnvironment?(profile) ?? profile.environment
        operation = Task {
            defer { if generation == token { isBusy = false; isCancelling = false; operation = nil } }
            do {
                await session.disconnect()
                isConnected = false
                try Task.checkCancellation()
                guard generation == token, !isClosed else { return }
                session = sessionFactory(demo)
                let info = try await session.connect(profile: profile, password: password)
                guard generation == token, !isClosed else { return }
                isConnected = true; isDemo = demo; serverVersion = info.serverVersion; transaction = .idle
                managedSession = ManagedSession(session: session, environment: profile.environment)
                managedSession?.restrictEnvironment(to: pendingEnvironmentRestriction)
                if let restriction = resolveProjectEnvironment?(profile) { restrictEnvironment(to: restriction) }
                commitMode = .manual; sessionIdentity = UUID(); transactionEpoch &+= 1; transactionStartedAt = nil
                invalidateEditableSnapshot()
                status = demo ? "Sample session" : "Connected"
                message = demo ? "Generated sample data. SQL is not sent to a server." : "Connected to \(profile.database) on \(profile.host):\(profile.port). Backend \(info.backendPID)."
            } catch { if generation == token { show(error) } }
        }
    }

    func run(sql override: String? = nil) {
        guard canIssueCommands, isConnected, !isBusy else { return }
        guard !hasPendingGridWork else { error = "Finish the cell editor, then preview/apply or discard grid drafts before running SQL."; return }
        let document = sql, selectedRange = selection
        isBusy = true; isCancelling = false; error = nil
        status = "Preparing statement…"
        let token = UUID(); generation = token
        let source = session
        operation = Task {
            var executingStore: ResultStore?
            defer {
                if generation == token { isBusy = false; isCancelling = false; operation = nil }
            }
            do {
                let parsing = Task.detached(priority: .userInitiated) {
                    if let override { return override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : override }
                    return try SQLStatementSelection.statement(in: document, selection: selectedRange)
                }
                let statement = try await withTaskCancellationHandler {
                    try await parsing.value
                } onCancel: { parsing.cancel() }
                try Task.checkCancellation()
                guard generation == token, !isClosed, !isClosing else { return }
                guard var statement else {
                    status = "No SQL statement"
                    message = "Place the cursor in a statement or highlight SQL to run."
                    return
                }
                if !isDemo, let managedSession {
                    let classifying = Task.detached { [statement] in try SQLTransactionControl.classify(statement) }
                    let classification = try await withTaskCancellationHandler { try await classifying.value } onCancel: { classifying.cancel() }
                    if classification != .ordinary {
                        let summary = try await managedSession.run(sql: statement, mode: commitMode) { _ in }
                        guard generation == token else { return }
                        updateTransaction(summary.transaction)
                        transactionEpoch &+= 1; invalidateEditableSnapshot()
                        status = summary.command; message = "\(summary.command) · \(summary.transaction.title)"
                        return
                    }
                    guard transaction != .failed else { throw DatabaseError("Roll back the failed transaction before running another statement.") }
                }
                if let resolveProjectMetadata { metadataProvider = try await resolveProjectMetadata() }
                guard generation == token, !Task.isCancelled else { return }
                let shouldEdit = override == nil && editTarget != nil && sql == ownedEditSQL
                    && statement.trimmingCharacters(in: .whitespacesAndNewlines) == sql.trimmingCharacters(in: .whitespacesAndNewlines)
                invalidateEditableSnapshot()
                editableTable = nil; editProjection = nil; editContext = nil; draftStore = nil
                draftRows = []; insertRows = []
                queryEditReadOnlyReason = nil; editExpressionsNeedRefresh = false
                if shouldEdit, let target = editTarget, let managedSession {
                    let provider = metadataProvider
                    let table = try await managedSession.withExclusiveOperation { session in
                        try await PostgresTableEditing.describe(relationOID: target.relationOID, on: session, metadataProvider: provider)
                    }
                    guard generation == token else { return }
                    guard table.schema == target.schema, table.name == target.name else {
                        throw DatabaseError("The table identity changed. Open it for editing again from Objects.")
                    }
                    if let reason = table.readOnlyReason { throw DatabaseError(reason) }
                    editableTable = table
                    statement = table.selectSQL()
                    sql = statement; ownedEditSQL = statement
                }
                resultIncomplete = true
                status = "Executing…"; message = "Waiting for PostgreSQL…"; rowCount = 0; columns = []; elapsed = 0
                selectedValue = nil; selectedColumn = nil; revision += 1
                let oldStore = store
                let resultStore = Self.makeStore(allowsSpooling: allowsSpooling)
                executingStore = resultStore; store = resultStore
                let relay = ProgressRelay()
                events.info("Query submitted")
                let interval = signposter.beginInterval("ExecuteAndStore")
                defer { signposter.endInterval("ExecuteAndStore", interval) }
                await oldStore.close()
                try await resultStore.reset()
                try Task.checkCancellation()
                guard generation == token, !isClosed else { return }
                let receive: @Sendable (QueryEvent) async throws -> Void = { [weak self] event in
                    switch event {
                    case .columns(let columns):
                        try await self?.receiveColumns(columns, token: token)
                    case .rows(let batch):
                        let count = try await resultStore.append(batch)
                        if await relay.shouldPublish() { await self?.receiveCount(count, token: token) }
                    case .notice(let text):
                        await self?.receiveNotice(text, token: token)
                    }
                }
                let summary: QuerySummary
                if !isDemo, let managedSession { summary = try await managedSession.run(sql: statement, mode: commitMode, requiresWritableTransaction: shouldEdit, onEvent: receive) }
                else { summary = try await source.execute(sql: statement, onEvent: receive) }
                guard generation == token else { return }
                let count = await resultStore.rowCount()
                guard generation == token, !isClosing, !isClosed else { return }
                rowCount = count
                updateTransaction(summary.transaction); elapsed = summary.elapsed
                if let table = editableTable {
                    editProjection = try ResultEditProjection(table: table, columns: columns, hasHiddenVersion: true)
                } else if !isDemo {
                    try await prepareQueryEditing(sql: statement, token: token)
                }
                guard generation == token, !isClosing, !isClosed else { return }
                if let table = editableTable {
                    let context = EditSourceContext(sessionID: sessionIdentity, resultRevision: UUID(), transactionEpoch: transactionEpoch,
                                                    relationOID: table.relationOID, metadataRevision: table.metadataRevision)
                    editContext = context; draftStore = EditDraftStore(context: context, table: table); editBaselineValid = true
                }
                status = "Complete"; resultIncomplete = false
                let countDescription = columns.isEmpty ? "\(summary.rowCount.formatted()) rows affected" : "\(rowCount.formatted()) rows"
                message = "\(summary.command) · \(countDescription) · \(String(format: "%.3f", elapsed)) s"
                events.info("Query completed; rows: \(self.rowCount)")
            } catch {
                guard generation == token else { return }
                if let executingStore {
                    // Consumer failures (including disk quota) must also stop PostgreSQL.
                    await source.cancel()
                    let count = await executingStore.rowCount()
                    guard generation == token, !isClosing, !isClosed else { return }
                    rowCount = count
                }
                let state = await source.transactionState()
                guard generation == token, !isClosing, !isClosed else { return }
                updateTransaction(state)
                if state == .idle || state == .unknown { transactionEpoch &+= 1; invalidateEditableSnapshot() }
                show(error)
            }
        }
    }

    private func receiveColumns(_ value: [DatabaseColumn], token: UUID) throws {
        guard generation == token else { return }
        if let table = editableTable {
            guard value.count == table.columns.count + 1,
                  zip(value, table.columns).allSatisfy({ $0.0.relationOID == table.relationOID && $0.0.attributeNumber == $0.1.attributeNumber
                      && ($0.1.kind == nil || $0.0.typeOID == $0.1.typeOID) }) else {
                throw DatabaseError("The result no longer matches the table metadata. Reload the table before editing.")
            }
        }
        columns = editableTable == nil ? value : Array(value.dropLast())
    }
    private func receiveCount(_ value: Int, token: UUID) { guard generation == token else { return }; rowCount = value; if !isCancelling { status = "Fetching…" }; message = "\(value.formatted()) rows received" }
    private func receiveNotice(_ value: String, token: UUID) { guard generation == token else { return }; message = String(value.prefix(8_192)) }

    func cancel() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true; status = "Cancelling…"
        signposter.emitEvent("CancelRequested")
        // The driver's task cancellation handler is bound to this operation ID.
        // A detached, session-wide cancel could arrive after the next Run begins.
        operation?.cancel()
    }
    func disconnect() {
        guard canIssueCommands, !isBusy, transaction == .idle else { return }
        guard !hasPendingGridWork else { error = "Apply or discard grid drafts before disconnecting."; return }
        invalidateConnectionIntent()
        isBusy = true
        let token = UUID(); generation = token
        operation = Task {
            await session.disconnect()
            guard generation == token, !isClosed else { return }
            isConnected = false; transaction = .unknown; status = "Disconnected"; isBusy = false; operation = nil
            invalidateEditableSnapshot(); managedSession = nil
        }
    }
    func exportCSV(to url: URL) {
        guard canIssueCommands, !isBusy, !columns.isEmpty else { return }
        guard !hasPendingGridWork else { error = "Apply or discard drafts before exporting fetched values."; return }
        guard editableTable == nil || editBaselineValid else { error = "Run the table query again before exporting this invalidated snapshot."; return }
        isBusy = true; isCancelling = false; status = "Exporting…"; error = nil
        let resultStore = store; let resultColumns = columns; let token = UUID(); generation = token
        operation = Task {
            defer { if generation == token { isBusy = false; isCancelling = false; operation = nil } }
            do {
                let count = try await resultStore.exportCSV(columns: resultColumns, to: url, trailingMetadataColumns: editProjection?.hasHiddenVersion == true ? 1 : 0)
                guard generation == token else { return }
                status = "Exported"; message = "Exported \(count.formatted()) fetched rows to \(url.lastPathComponent)."
            } catch { if generation == token { show(error) } }
        }
    }
    func prepareToClose() {
        guard !isClosing, !isClosed else { return }
        isClosing = true; isLoading = false; status = "Closing…"
        generation = UUID(); connectionIntent = UUID(); loadGeneration = UUID()
        cellEditor.cancel(); lookup?.cancel(); lookup = nil; previewPlan = nil; clearVerifiedEditRow()
        operation?.cancel()
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        guard !isClosed else { return }
        prepareToClose()
        let source = session; let resultStore = store
        let task = Task {
            // The PostgreSQL driver closes its owned socket on its utility queue;
            // it does not wait for a server response or transaction rollback.
            await source.disconnect()
            await resultStore.close()
            await releaseProjectMetadata?()
            await draftStore?.discard(); draftStore = nil; draftRows = []; insertRows = []; editConflict = nil
            operation = nil; closeTask = nil
            isBusy = false; isConnected = false; isClosed = true; isClosing = false; isClosePending = false
        }
        closeTask = task
        await task.value
    }
    func show(_ failure: Error) {
        let dbError = failure as? DatabaseError
        error = failure.localizedDescription
        status = dbError?.sqlState == "57014" || failure is CancellationError ? "Cancelled" : "Query failed"
        if dbError?.commitOutcomeUnknown == true { status = "Outcome unknown"; invalidateEditableSnapshot() }
        message = failure.localizedDescription
        if let sqlState = dbError?.sqlState { message += " [\(sqlState)]" }
        if dbError?.connectionLost == true { isConnected = false; transaction = .unknown }
        events.error("Query/session failed")
    }
}
