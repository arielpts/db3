import Foundation
import DB3Core
@testable import DB3Workbench

actor MemoryWorkbenchPersistence: WorkbenchPersistence {
    struct Write: Equatable, Sendable { let sql: String; let url: URL }
    struct PasswordWrite: Equatable, Sendable { let password: String; let profileID: UUID }
    private var files: [URL: String] = [:]
    private var heldReads: Set<URL> = []
    private var readContinuations: [URL: [CheckedContinuation<String, any Error>]] = [:]
    private var heldPasswords: Set<UUID> = []
    private var passwordContinuations: [UUID: [CheckedContinuation<String, any Error>]] = [:]
    private var passwordResults: [UUID: Result<String, DatabaseError>] = [:]
    private var writeContinuations: [CheckedContinuation<Void, any Error>] = []
    private var holdsWrites = false
    private var writeFailure: DatabaseError?
    private(set) var reads: [URL] = []
    private(set) var passwordReads: [UUID] = []
    private(set) var passwordWrites: [PasswordWrite] = []
    private(set) var profileWrites: [[ConnectionProfile]] = []
    private(set) var writes: [Write] = []
    private(set) var profiles: [ConnectionProfile] = []

    func loadProfiles() async throws -> [ConnectionProfile] { profiles }
    func saveProfiles(_ profiles: [ConnectionProfile]) async throws {
        profileWrites.append(profiles)
        self.profiles = profiles
    }
    func savePassword(_ password: String, for id: UUID) async throws {
        passwordWrites.append(PasswordWrite(password: password, profileID: id))
    }
    func password(for id: UUID) async throws -> String {
        passwordReads.append(id)
        if heldPasswords.contains(id) {
            return try await withCheckedThrowingContinuation { passwordContinuations[id, default: []].append($0) }
        }
        return try passwordResults[id]?.get() ?? "test-password"
    }
    func readSQL(at url: URL) async throws -> String {
        reads.append(url)
        if heldReads.contains(url) {
            return try await withCheckedThrowingContinuation { readContinuations[url, default: []].append($0) }
        }
        guard let text = files[url] else { throw DatabaseError("Simulated read failure") }
        return text
    }
    func writeSQL(_ sql: String, at url: URL) async throws {
        writes.append(Write(sql: sql, url: url))
        if let writeFailure { throw writeFailure }
        if holdsWrites { try await withCheckedThrowingContinuation { writeContinuations.append($0) } }
        files[url] = sql
    }
    func setFile(_ text: String, at url: URL) { files[url] = text }
    func holdRead(at url: URL) { heldReads.insert(url) }
    func finishRead(at url: URL, text: String) {
        heldReads.remove(url)
        for continuation in readContinuations.removeValue(forKey: url) ?? [] { continuation.resume(returning: text) }
    }
    func holdPassword(for id: UUID) { heldPasswords.insert(id) }
    func setPassword(_ value: String, for id: UUID) { passwordResults[id] = .success(value) }
    func failPasswordReads(for id: UUID) {
        passwordResults[id] = .failure(DatabaseError("Simulated Keychain read failure (-25293)."))
    }
    func finishPassword(for id: UUID, value: String) {
        heldPasswords.remove(id)
        for continuation in passwordContinuations.removeValue(forKey: id) ?? [] { continuation.resume(returning: value) }
    }
    func failPendingPassword(for id: UUID) {
        heldPasswords.remove(id)
        for continuation in passwordContinuations.removeValue(forKey: id) ?? [] {
            continuation.resume(throwing: DatabaseError("Simulated Keychain read failure (-25293)."))
        }
    }
    func holdWrites() { holdsWrites = true }
    func failWrites() { writeFailure = DatabaseError("Simulated write failure") }
    func finishWrites() {
        holdsWrites = false
        let continuations = writeContinuations; writeContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
final class ScriptedWorkbenchDialogs: WorkbenchDialogs {
    var closeDecisions: [WorksheetCloseDecision] = []
    var saveURL: URL?
    var holdSavePanel = false
    var holdCloseDecision = false
    private(set) var snapshots: [WorksheetCloseSnapshot] = []
    private(set) var savePanelTitles: [String] = []
    private var saveContinuation: CheckedContinuation<URL?, Never>?
    private var closeContinuation: CheckedContinuation<WorksheetCloseDecision, Never>?

    func chooseOpenSQL() async -> URL? { nil }
    func chooseExportCSV() async -> URL? { nil }
    func chooseSaveSQL(title: String, currentURL: URL?) async -> URL? {
        savePanelTitles.append(title)
        if holdSavePanel { return await withCheckedContinuation { saveContinuation = $0 } }
        return saveURL
    }
    func confirmClose(_ snapshot: WorksheetCloseSnapshot) async -> WorksheetCloseDecision {
        snapshots.append(snapshot)
        if holdCloseDecision { return await withCheckedContinuation { closeContinuation = $0 } }
        return closeDecisions.isEmpty ? .keepOpen : closeDecisions.removeFirst()
    }
    func finishSavePanel(_ url: URL?) {
        holdSavePanel = false
        let continuation = saveContinuation; saveContinuation = nil
        continuation?.resume(returning: url)
    }
    func finishClose(_ decision: WorksheetCloseDecision) {
        holdCloseDecision = false
        let continuation = closeContinuation; closeContinuation = nil
        continuation?.resume(returning: decision)
    }
}

actor RecordingDatabaseSession: DatabaseSession {
    struct Connection: Equatable, Sendable { let profile: ConnectionProfile; let password: String }
    private(set) var connections: [Connection] = []
    /// Every driver command, including the coordinator's implicit controls.
    private(set) var commands: [String] = []
    /// Ordinary SQL only; existing result-pipeline assertions use this list.
    private(set) var queries: [String] = []
    private(set) var disconnectCount = 0
    private(set) var cancelCount = 0
    private var holdExecution = false
    private var holdConnect = false
    private var holdDisconnect = false
    private var executionContinuation: CheckedContinuation<Void, any Error>?
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var disconnectContinuations: [CheckedContinuation<Void, Never>] = []
    private var transaction = TransactionState.idle
    private var failures: [String: (DatabaseError, TransactionState?)] = [:]

    func connect(profile: ConnectionProfile, password: String) async throws -> SessionInfo {
        connections.append(Connection(profile: profile, password: password))
        if holdConnect { try await withCheckedThrowingContinuation { connectContinuation = $0 } }
        try Task.checkCancellation()
        transaction = .idle
        return SessionInfo(serverVersion: "fake", backendPID: connections.count)
    }
    func execute(sql: String, onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        commands.append(sql)
        let control = try SQLTransactionControl.classify(sql)
        if let (error, state) = failures[sql] {
            transaction = state ?? (transaction == .inTransaction ? .failed : transaction)
            if control == .ordinary { queries.append(sql) }
            throw error
        }
        if control != .ordinary {
            try Task.checkCancellation()
            let command: String
            switch control {
            case .begin: transaction = .inTransaction; command = "BEGIN"
            case .commit:
                command = transaction == .failed ? "ROLLBACK" : "COMMIT"
                transaction = sql.uppercased().contains("AND CHAIN") ? .inTransaction : .idle
            case .rollback:
                transaction = sql.uppercased().contains("AND CHAIN") ? .inTransaction : .idle; command = "ROLLBACK"
            case .rollbackToSavepoint: transaction = .inTransaction; command = "ROLLBACK"
            case .savepoint: command = "SAVEPOINT"
            case .releaseSavepoint: command = "RELEASE"
            case .setTransaction: command = "SET"
            default: throw DatabaseError("Unsupported transaction test command.")
            }
            return QuerySummary(command: command, rowCount: 0, transaction: transaction, elapsed: 0.01)
        }
        queries.append(sql)
        if holdExecution { try await withCheckedThrowingContinuation { executionContinuation = $0 } }
        try Task.checkCancellation()
        try await onEvent(.columns([DatabaseColumn(index: 0, name: "query")]))
        try await onEvent(.rows(RowBatch(rows: [[.text(sql)]])))
        return QuerySummary(command: "SELECT", rowCount: 1, transaction: transaction, elapsed: 0.01)
    }
    func cancel() async { cancelCount += 1 }
    func disconnect() async {
        disconnectCount += 1
        if holdDisconnect { await withCheckedContinuation { disconnectContinuations.append($0) } }
        if let executionContinuation { self.executionContinuation = nil; executionContinuation.resume(throwing: CancellationError()) }
        if let connectContinuation { self.connectContinuation = nil; connectContinuation.resume(throwing: CancellationError()) }
        transaction = .unknown
    }
    func transactionState() async -> TransactionState { transaction }
    func failExecution(of sql: String, with error: DatabaseError, state: TransactionState? = nil) { failures[sql] = (error, state) }
    func clearExecutionFailures() { failures.removeAll() }
    func suspendConnect() { holdConnect = true }
    func finishConnect() {
        holdConnect = false
        let continuation = connectContinuation; connectContinuation = nil
        continuation?.resume()
    }
    func suspendExecution() { holdExecution = true }
    func finishExecution() {
        holdExecution = false
        let continuation = executionContinuation; executionContinuation = nil
        continuation?.resume()
    }
    func suspendDisconnect() { holdDisconnect = true }
    func finishDisconnect() {
        holdDisconnect = false
        let continuations = disconnectContinuations; disconnectContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
final class WorkbenchFixture {
    let persistence = MemoryWorkbenchPersistence()
    let dialogs = ScriptedWorkbenchDialogs()
    private(set) var sessions: [RecordingDatabaseSession] = []
    lazy var model: WorkbenchModel = WorkbenchModel(persistence: persistence, dialogs: dialogs, worksheetFactory: { [unowned self] title in
        let session = RecordingDatabaseSession()
        self.sessions.append(session)
        return Worksheet(title: title, sessionFactory: { _ in session })
    })
}
