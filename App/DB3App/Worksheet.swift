import Foundation
import Observation
import OSLog
import DB3Core
import DB3Postgres
import DB3Results

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
    var sql = "-- Write a query, or select a statement to run.\nSELECT current_database(), current_user, version();"
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
    var serverVersion = ""
    var elapsed: TimeInterval = 0
    var selectedValue: String?
    var selectedColumn: String?
    var error: String?
    var resultIncomplete = false
    var allowsSpooling = true
    private(set) var isClosed = false
    // Four worksheet slots divide the application budget rather than multiplying it.
    @ObservationIgnored var store = Worksheet.makeStore(allowsSpooling: true)
    @ObservationIgnored private var session: any DatabaseSession = PostgresSession()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(title: String = "Query 1") { self.title = title }
    private static func makeStore(allowsSpooling: Bool) -> ResultStore {
        ResultStore(configuration: .init(residentByteLimit: 16 * 1_024 * 1_024, spoolByteLimit: 1_024 * 1_024 * 1_024, sharedSpoolBudget: spoolBudget, allowsSpooling: allowsSpooling, maximumBatchBytes: 2 * 1_024 * 1_024))
    }

    func connect(_ profile: ConnectionProfile, password: String, demo: Bool = false) {
        guard !isClosed, !isBusy else { return }
        guard transaction != .inTransaction, transaction != .failed else { error = "Commit or roll back before changing connections."; return }
        let token = UUID(); generation = token
        isBusy = true; error = nil; status = "Connecting…"; self.profile = profile
        operation = Task {
            defer { if generation == token { isBusy = false; isCancelling = false; operation = nil } }
            do {
                await session.disconnect()
                isConnected = false
                try Task.checkCancellation()
                guard generation == token, !isClosed else { return }
                session = demo ? DemoSession() : PostgresSession()
                let info = try await session.connect(profile: profile, password: password)
                guard generation == token, !isClosed else { return }
                isConnected = true; isDemo = demo; serverVersion = info.serverVersion; transaction = .idle
                status = demo ? "Sample session" : "Connected"
                message = demo ? "Generated sample data. SQL is not sent to a server." : "Connected to \(profile.database) on \(profile.host):\(profile.port). Backend \(info.backendPID)."
            } catch { if generation == token { show(error) } }
        }
    }

    func run(sql override: String? = nil) {
        guard !isClosed, isConnected, !isBusy else { return }
        let text = sql as NSString
        let statement = override ?? (selection.length > 0 && NSMaxRange(selection) <= text.length ? text.substring(with: selection) : sql)
        guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isBusy = true; isCancelling = false; error = nil; resultIncomplete = true
        status = "Executing…"; message = "Waiting for PostgreSQL…"; rowCount = 0; columns = []; elapsed = 0
        selectedValue = nil; selectedColumn = nil; revision += 1
        let token = UUID(); generation = token
        let source = session; let oldStore = store
        let resultStore = Self.makeStore(allowsSpooling: allowsSpooling)
        store = resultStore
        let relay = ProgressRelay()
        events.info("Query submitted")
        let interval = signposter.beginInterval("ExecuteAndStore")
        operation = Task {
            defer { signposter.endInterval("ExecuteAndStore", interval) }
            do {
                await oldStore.close()
                try await resultStore.reset()
                try Task.checkCancellation()
                guard generation == token, !isClosed else { return }
                let summary = try await source.execute(sql: statement) { [weak self] event in
                    switch event {
                    case .columns(let columns):
                        await self?.receiveColumns(columns, token: token)
                    case .rows(let batch):
                        let count = try await resultStore.append(batch)
                        if await relay.shouldPublish() { await self?.receiveCount(count, token: token) }
                    case .notice(let text):
                        await self?.receiveNotice(text, token: token)
                    }
                }
                guard generation == token else { return }
                rowCount = await resultStore.rowCount()
                transaction = summary.transaction; elapsed = summary.elapsed
                status = "Complete"; resultIncomplete = false
                let countDescription = columns.isEmpty ? "\(summary.rowCount.formatted()) rows affected" : "\(rowCount.formatted()) rows"
                message = "\(summary.command) · \(countDescription) · \(String(format: "%.3f", elapsed)) s"
                events.info("Query completed; rows: \(self.rowCount)")
            } catch {
                guard generation == token else { return }
                // Consumer failures (including disk quota) must also stop PostgreSQL.
                await source.cancel()
                rowCount = await resultStore.rowCount()
                transaction = await source.transactionState()
                show(error)
            }
            guard generation == token else { return }
            isBusy = false; isCancelling = false; operation = nil
        }
    }

    private func receiveColumns(_ value: [DatabaseColumn], token: UUID) { guard generation == token else { return }; columns = value }
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
        guard !isClosed, !isBusy, transaction == .idle else { return }
        isBusy = true
        Task { await session.disconnect(); isConnected = false; transaction = .unknown; status = "Disconnected"; isBusy = false }
    }
    func exportCSV(to url: URL) {
        guard !isClosed, !isBusy, !columns.isEmpty else { return }
        isBusy = true; isCancelling = false; status = "Exporting…"; error = nil
        let resultStore = store; let resultColumns = columns; let token = generation
        operation = Task {
            defer { if generation == token { isBusy = false; isCancelling = false; operation = nil } }
            do {
                let count = try await resultStore.exportCSV(columns: resultColumns, to: url)
                guard generation == token else { return }
                status = "Exported"; message = "Exported \(count.formatted()) fetched rows to \(url.lastPathComponent)."
            } catch { if generation == token { show(error) } }
        }
    }
    func prepareToClose() {
        isClosed = true; isBusy = false; isConnected = false
        generation = UUID()
        operation?.cancel()
    }
    func close() async {
        prepareToClose()
        await session.disconnect()
        await store.close()
        operation = nil
    }
    private func show(_ failure: Error) {
        let dbError = failure as? DatabaseError
        error = failure.localizedDescription
        status = dbError?.sqlState == "57014" || failure is CancellationError ? "Cancelled" : "Query failed"
        message = failure.localizedDescription
        if let sqlState = dbError?.sqlState { message += " [\(sqlState)]" }
        if dbError?.connectionLost == true { isConnected = false; transaction = .unknown }
        events.error("Query/session failed")
    }
}
