import Foundation

/// Owns the operation lease for a worksheet's pinned physical session. Actor
/// isolation alone would allow a second operation to interleave at each await.
/// Contenders are rejected, not enqueued into an unbounded waiting list.
public actor ManagedSession {
    private let session: any DatabaseSession
    public nonisolated let environment: ConnectionEnvironment
    private nonisolated let policy: ManagedSessionPolicy
    public nonisolated var effectiveEnvironment: ConnectionEnvironment { policy.environment }
    private var operationInProgress = false
    public private(set) var transactionBeganAt: Date?
    public private(set) var transactionEpoch: UInt64 = 0

    public init(session: any DatabaseSession, environment: ConnectionEnvironment) {
        self.session = session; self.environment = environment; policy = ManagedSessionPolicy(environment)
    }

    /// Profile reclassification can tighten a live session while its actor is
    /// suspended in I/O. Synchronous locking applies that restriction before
    /// a later automatic boundary, without waiting for an actor hop or lease.
    /// Loosening classification always requires a new physical connection.
    public nonisolated func restrictEnvironment(to environment: ConnectionEnvironment) { policy.restrict(to: environment) }

    /// Atomic Apply calls this again immediately before its automatic COMMIT.
    /// Explicit user Commit uses a separate path and remains allowed in Manual.
    public nonisolated func authorizeAutoCommit() throws {
        try Self.checkPolicy(mode: .auto, environment: effectiveEnvironment)
    }

    public func transactionState() async -> TransactionState { await session.transactionState() }

    /// This validates policy and current server state only. The worksheet also
    /// resolves its local drafts before changing its persistent per-tab mode.
    public func validateModeChange(to mode: CommitMode) async throws {
        try await withExclusiveOperation { session in
            try Self.checkPolicy(mode: mode, environment: self.effectiveEnvironment)
            guard await session.transactionState() == .idle else {
                throw DatabaseError("Commit or roll back the current transaction before changing commit mode.")
            }
            try Self.checkPolicy(mode: mode, environment: self.effectiveEnvironment)
        }
    }

    /// Trusted metadata, lookup, and atomic Apply code uses the same owner. The
    /// closure must not escape the raw session or recursively acquire this lease.
    public func withExclusiveOperation<T: Sendable>(
        _ operation: @Sendable (any DatabaseSession) async throws -> T
    ) async throws -> T {
        try await perform(operation)
    }

    /// Explicit table editing requests a writable transaction only when this
    /// operation creates one. An existing transaction keeps its user's settings.
    public func run(sql: String, mode: CommitMode, requiresWritableTransaction: Bool = false,
                    onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        try Self.checkPolicy(mode: mode, environment: effectiveEnvironment)
        let words = try SQLTransactionControl.leadingKeywords(sql)
        let control = SQLTransactionControl.classify(words)
        let chained = words.suffix(2).elementsEqual(["AND", "CHAIN"])
        return try await perform(endsTransaction: control.endsTransaction) { session in
            try Task.checkCancellation()
            let state = await session.transactionState()
            try Self.checkPolicy(mode: mode, environment: self.effectiveEnvironment)
            guard state != .unknown else { throw DatabaseError("The session's transaction state is unknown. Reconnect before running SQL.", connectionLost: true) }
            guard control != .unsupported else { throw DatabaseError("Two-phase transactions are not supported in a managed worksheet.") }
            if control == .commit { return try await Self.commit(sql: sql, chained: chained, session: session, onEvent: onEvent) }
            if state == .failed, control != .rollback, control != .rollbackToSavepoint {
                throw DatabaseError("This transaction has failed. Roll back before running another statement.")
            }
            if control == .begin, state == .inTransaction {
                throw DatabaseError("A transaction is already open. Commit or roll it back before starting another.")
            }
            if mode == .manual, state == .idle,
               control == .ordinary || control == .savepoint || control == .setTransaction {
                let began = try await session.execute(sql: requiresWritableTransaction ? "BEGIN READ WRITE" : "BEGIN") { _ in }
                guard began.command == "BEGIN", began.transaction == .inTransaction else {
                    throw DatabaseError("PostgreSQL did not confirm the transaction start. The statement was not sent.")
                }
                try Task.checkCancellation()
            }
            try Self.checkPolicy(mode: mode, environment: self.effectiveEnvironment)
            try Task.checkCancellation()
            let summary = try await session.execute(sql: sql, onEvent: onEvent)
            if control == .rollback {
                guard summary.command == "ROLLBACK", summary.transaction == (chained ? .inTransaction : .idle) else {
                    throw DatabaseError("PostgreSQL did not confirm the requested rollback. Check the transaction state before continuing.")
                }
            }
            return summary
        }
    }

    public func commit(onEvent: @escaping @Sendable (QueryEvent) async throws -> Void = { _ in }) async throws -> QuerySummary {
        try await perform(endsTransaction: true) { session in
            try Task.checkCancellation()
            return try await Self.commit(sql: "COMMIT", chained: false, session: session, onEvent: onEvent)
        }
    }

    public func rollback(onEvent: @escaping @Sendable (QueryEvent) async throws -> Void = { _ in }) async throws -> QuerySummary {
        try await run(sql: "ROLLBACK", mode: .manual, onEvent: onEvent)
    }

    private func perform<T: Sendable>(endsTransaction: Bool = false,
        _ operation: @Sendable (any DatabaseSession) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !operationInProgress else { throw DatabaseError("This worksheet already has an operation in progress.") }
        operationInProgress = true
        defer { operationInProgress = false }
        let before = await session.transactionState()
        do {
            let value = try await operation(session)
            let after = await session.transactionState()
            updateTransaction(before: before, after: after, boundary: endsTransaction)
            return value
        } catch {
            let after = await session.transactionState()
            updateTransaction(before: before, after: after, boundary: false)
            throw error
        }
    }

    private func updateTransaction(before: TransactionState, after: TransactionState, boundary: Bool) {
        let wasOpen = before == .inTransaction || before == .failed
        let isOpen = after == .inTransaction || after == .failed
        if wasOpen != isOpen || boundary { transactionEpoch &+= 1 }
        if isOpen {
            if transactionBeganAt == nil || !wasOpen || boundary { transactionBeganAt = Date() }
        } else { transactionBeganAt = nil }
    }

    private static func checkPolicy(mode: CommitMode, environment: ConnectionEnvironment) throws {
        guard mode != .auto || environment.allowsAutoCommit else {
            throw DatabaseError("Auto commit is available only for connections explicitly classified as Development. This connection requires Manual mode.")
        }
    }

    private static func commit(sql: String, chained: Bool, session: any DatabaseSession,
                               onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        guard await session.transactionState() != .unknown else {
            throw DatabaseError("The session's transaction state is unknown. Reconnect before committing.", connectionLost: true)
        }
        try Task.checkCancellation()
        let summary: QuerySummary
        do { summary = try await session.execute(sql: sql, onEvent: onEvent) }
        catch {
            let state = await session.transactionState()
            let databaseError = error as? DatabaseError
            if databaseError?.connectionLost == true || state == .unknown || (error is CancellationError && state == .idle) {
                throw DatabaseError("Commit outcome is unknown because its acknowledgement was lost. Do not replay the changes automatically. Reconnect and verify the affected rows.",
                                    sqlState: databaseError?.sqlState, connectionLost: databaseError?.connectionLost == true || state == .unknown,
                                    commitOutcomeUnknown: true)
            }
            throw error
        }
        if summary.command == "ROLLBACK" {
            throw DatabaseError("PostgreSQL rolled back the transaction instead of committing it. No commit was confirmed.")
        }
        guard summary.command == "COMMIT", summary.transaction == (chained ? .inTransaction : .idle) else {
            throw DatabaseError("Commit outcome is unknown: PostgreSQL did not return the expected commit acknowledgement. Do not replay the changes automatically.",
                                connectionLost: summary.transaction == .unknown, commitOutcomeUnknown: true)
        }
        return summary
    }
}

/// The only unchecked boundary is a tiny synchronous policy value; no database
/// I/O, callbacks, continuations or awaited work happens under this lock.
private final class ManagedSessionPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConnectionEnvironment
    init(_ environment: ConnectionEnvironment) { value = environment }
    var environment: ConnectionEnvironment {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func restrict(to environment: ConnectionEnvironment) {
        lock.lock(); defer { lock.unlock() }
        if environment == .production { value = .production }
        else if environment == .unknown, value == .development { value = .unknown }
    }
}
