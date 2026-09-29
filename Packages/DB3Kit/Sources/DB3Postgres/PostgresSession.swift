import Foundation
import Dispatch
import Darwin
import CLibPQ
import DB3Core

/// A worksheet owns one session. All C calls, decoding, and socket callbacks run
/// on a private utility queue; async consumers receive owned Swift values only.
public final class PostgresSession: DatabaseSession, Sendable {
    private let owner = ConnectionOwner()

    public init() {}

    deinit { owner.shutdown() }

    public func connect(profile: ConnectionProfile, password: String) async throws -> SessionInfo {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                owner.enqueueConnect(id: id, profile: profile, password: password, continuation: continuation)
            }
        } onCancel: { owner.cancelOperation(id) }
    }

    public func execute(sql: String, onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        try await execute(sql: sql, parameters: [], onEvent: onEvent)
    }

    /// Text parameters remain separate from SQL. nil represents SQL NULL.
    /// The extended protocol still accepts exactly one statement per call.
    public func execute(sql: String, parameters: [String?], onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                owner.enqueueQuery(id: id, sql: sql, parameters: parameters, consumer: onEvent, continuation: continuation)
            }
        } onCancel: { owner.cancelOperation(id) }
    }

    /// Acknowledges the request. `execute` settles only after protocol recovery.
    public func cancel() async {
        await withCheckedContinuation { continuation in
            owner.requestCancel(continuation: continuation)
        }
    }

    public func disconnect() async {
        await withCheckedContinuation { continuation in
            owner.shutdown(continuation: continuation)
        }
    }

    public func transactionState() async -> TransactionState {
        await withCheckedContinuation { continuation in
            owner.readTransactionState(continuation)
        }
    }
}

private final class Connecting {
    let id: UUID
    let continuation: CheckedContinuation<SessionInfo, any Error>
    init(id: UUID, continuation: CheckedContinuation<SessionInfo, any Error>) {
        self.id = id; self.continuation = continuation
    }
}

private final class Query {
    let id: UUID
    let continuation: CheckedContinuation<QuerySummary, any Error>
    let consumer: @Sendable (QueryEvent) async throws -> Void
    let started = DispatchTime.now().uptimeNanoseconds
    var columnsDelivered = false
    var rows: [DatabaseRow] = []
    var bytes = 0
    var totalRows = 0
    var command = ""
    var error: (any Error)?
    var complete = false
    var cancelRequested = false
    var consumerTask: Task<Void, Never>?
    var deliveryID: UUID?
    init(id: UUID, consumer: @escaping @Sendable (QueryEvent) async throws -> Void, continuation: CheckedContinuation<QuerySummary, any Error>) {
        self.id = id; self.consumer = consumer; self.continuation = continuation
    }
}

/// This is the sole unchecked boundary: every mutable property and C pointer is
/// confined to `queue`. Public methods only enqueue Sendable inputs. Pointers
/// never enter Tasks or continuations. The public facade schedules shutdown on
/// deinit, retaining this owner until all native resources have been released.
private final class ConnectionOwner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.db3.postgres.connection", qos: .utility)
    private var connection: OpaquePointer?
    private var cancellation: OpaquePointer?
    private var connecting: Connecting?
    private var query: Query?
    private var deadline: (any DispatchSourceTimer)?
    private var recoveryDeadline: (any DispatchSourceTimer)?
    private var partialBatchDeadline: (any DispatchSourceTimer)?
    private var readWatch: (any DispatchSourceRead)?
    private var writeWatch: (any DispatchSourceWrite)?
    private var cancelReadWatch: (any DispatchSourceRead)?
    private var cancelWriteWatch: (any DispatchSourceWrite)?
    private var readEpoch: UInt64 = 0
    private var writeEpoch: UInt64 = 0
    private var cancelEpoch: UInt64 = 0
    private var preCancelled: [UUID] = []
    private var notices: [String] = []
    private var noticeBytes = 0

    func enqueueConnect(id: UUID, profile: ConnectionProfile, password: String, continuation: CheckedContinuation<SessionInfo, any Error>) {
        queue.async { self.beginConnect(id: id, profile: profile, password: password, continuation: continuation) }
    }

    func enqueueQuery(id: UUID, sql: String, parameters: [String?], consumer: @escaping @Sendable (QueryEvent) async throws -> Void, continuation: CheckedContinuation<QuerySummary, any Error>) {
        queue.async { self.beginQuery(id: id, sql: sql, parameters: parameters, consumer: consumer, continuation: continuation) }
    }

    func cancelOperation(_ id: UUID) {
        queue.async {
            if self.connecting?.id == id {
                self.close(error: CancellationError())
            } else if self.query?.id == id {
                self.startCancellation()
            } else {
                // Also covers cancellation arriving just before enqueueConnect/
                // enqueueQuery. Keep late cancellation bookkeeping bounded.
                self.preCancelled.append(id)
                if self.preCancelled.count > 128 { self.preCancelled.removeFirst() }
            }
        }
    }

    func requestCancel(continuation: CheckedContinuation<Void, Never>) {
        queue.async {
            if self.connecting != nil { self.close(error: CancellationError()) }
            else { self.startCancellation() }
            continuation.resume()
        }
    }

    func shutdown(continuation: CheckedContinuation<Void, Never>? = nil) {
        queue.async {
            self.close(error: DatabaseError("The session was disconnected.", connectionLost: true))
            continuation?.resume()
        }
    }

    func readTransactionState(_ continuation: CheckedContinuation<TransactionState, Never>) {
        queue.async { continuation.resume(returning: self.currentTransactionState()) }
    }

    private func wasCancelled(_ id: UUID) -> Bool {
        guard let index = preCancelled.firstIndex(of: id) else { return false }
        preCancelled.remove(at: index)
        return true
    }

    private func beginConnect(id: UUID, profile: ConnectionProfile, password: String, continuation: CheckedContinuation<SessionInfo, any Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !wasCancelled(id) else { continuation.resume(throwing: CancellationError()); return }
        guard connecting == nil, query == nil else {
            continuation.resume(throwing: DatabaseError("This session is busy. Wait for it to finish before reconnecting.")); return
        }
        guard (1...65535).contains(profile.port), !profile.host.isEmpty,
              ![profile.host, profile.database, profile.username, profile.rootCertificate, password].contains(where: { $0.utf8.contains(0) }) else {
            continuation.resume(throwing: DatabaseError("Connection settings contain an invalid host, port, or NUL character.")); return
        }
        close(error: DatabaseError("The session is reconnecting.", connectionLost: true))
        connecting = Connecting(id: id, continuation: continuation)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.connecting?.id == id else { return }
            self.close(error: DatabaseError("Connection timed out after 15 seconds.", connectionLost: true))
        }
        deadline = timer
        timer.resume()
        HostResolver.shared.resolve(profile.host) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.connecting?.id == id else { return }
                switch result {
                case .failure(let error): self.close(error: error)
                case .success(let addresses): self.startConnection(profile: profile, password: password, addresses: addresses)
                }
            }
        }
    }

    private func startConnection(profile: ConnectionProfile, password: String, addresses: [String]) {
        var parameters = [
            ("host", addresses.isEmpty ? profile.host : Array(repeating: profile.host, count: addresses.count).joined(separator: ",")),
            ("port", String(profile.port)), ("dbname", profile.database),
            ("user", profile.username), ("password", password),
            ("sslmode", profile.tls == .verifyFull ? "verify-full" : profile.tls.rawValue),
            ("client_encoding", "UTF8"), ("application_name", "db3"),
            ("connect_timeout", "15"), ("gssencmode", "disable"),
        ]
        if !addresses.isEmpty { parameters.append(("hostaddr", addresses.joined(separator: ","))) }
        if !profile.rootCertificate.isEmpty {
            parameters.append(("sslrootcert", (profile.rootCertificate as NSString).expandingTildeInPath))
        } else if profile.tls == .verifyFull {
            // Avoid a native dependency's build-machine OpenSSL root path.
            // macOS supplies this PEM bundle independently of Homebrew.
            parameters.append(("sslrootcert", "/etc/ssl/cert.pem"))
        }
        let keys = parameters.map { strdup($0.0) }
        let values = parameters.map { strdup($0.1) }
        defer { keys.forEach { free($0) }; values.forEach { free($0) } }
        let keyPointers: [UnsafePointer<CChar>?] = keys.map { pointer in pointer.map { UnsafePointer<CChar>($0) } } + [nil]
        let valuePointers: [UnsafePointer<CChar>?] = values.map { pointer in pointer.map { UnsafePointer<CChar>($0) } } + [nil]
        connection = keyPointers.withUnsafeBufferPointer { keys in
            valuePointers.withUnsafeBufferPointer { values in
                PQconnectStartParams(keys.baseAddress, values.baseAddress, 0)
            }
        }
        guard let connection else { close(error: DatabaseError("libpq could not allocate a connection.", connectionLost: true)); return }
        // libpq has no public startup-error SQLSTATE accessor. Its documented
        // verbose format preserves that field while authenticating; restore
        // normal query diagnostics as soon as startup succeeds.
        PQsetErrorVerbosity(connection, PQERRORS_VERBOSE)
        PQsetNoticeReceiver(connection, { context, result in
            guard let context, let result else { return }
            Unmanaged<ConnectionOwner>.fromOpaque(context).takeUnretainedValue().receiveNotice(result)
        }, Unmanaged.passUnretained(self).toOpaque())
        guard PQstatus(connection) != CONNECTION_BAD else { close(error: connectionError()); return }
        // The first poll must wait for write readiness; subsequent polls can
        // change sockets while trying the resolved address list.
        watchSocket(read: false)
    }

    private func pollConnection() {
        guard let connection, connecting != nil else { return }
        switch PQconnectPoll(connection) {
        case PGRES_POLLING_READING: watchSocket(read: true)
        case PGRES_POLLING_WRITING: watchSocket(read: false)
        case PGRES_POLLING_OK:
            PQsetErrorVerbosity(connection, PQERRORS_DEFAULT)
            guard PQsetnonblocking(connection, 1) == 0 else { close(error: connectionError()); return }
            guard isUTF8 else { close(error: DatabaseError("PostgreSQL did not accept UTF-8 client encoding.", connectionLost: true)); return }
            deadline?.cancel(); deadline = nil
            let attempt = connecting
            connecting = nil
            let version = PQparameterStatus(connection, "server_version").map { String(cString: $0) } ?? String(PQserverVersion(connection))
            attempt?.continuation.resume(returning: SessionInfo(serverVersion: version, backendPID: Int(PQbackendPID(connection))))
        case PGRES_POLLING_ACTIVE: queue.async { self.pollConnection() }
        default: close(error: connectionError())
        }
    }

    private func beginQuery(id: UUID, sql: String, parameters: [String?], consumer: @escaping @Sendable (QueryEvent) async throws -> Void, continuation: CheckedContinuation<QuerySummary, any Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !wasCancelled(id) else { continuation.resume(throwing: CancellationError()); return }
        guard connecting == nil, query == nil else {
            continuation.resume(throwing: DatabaseError("This worksheet already has an operation in progress.")); return
        }
        guard let connection, PQstatus(connection) == CONNECTION_OK else {
            continuation.resume(throwing: DatabaseError("Connect to PostgreSQL before executing SQL.", connectionLost: true)); return
        }
        guard isUTF8 else { continuation.resume(throwing: encodingError()); return }
        guard !sql.utf8.contains(0) else {
            continuation.resume(throwing: DatabaseError("SQL cannot contain a NUL character.")); return
        }
        guard parameters.count <= 65_535, !parameters.contains(where: { $0?.utf8.contains(0) == true }) else {
            continuation.resume(throwing: DatabaseError("SQL parameters contain a NUL character or exceed the PostgreSQL parameter limit.")); return
        }
        query = Query(id: id, consumer: consumer, continuation: continuation)
        notices.removeAll(keepingCapacity: true); noticeBytes = 0
        // libpq copies parameter bytes before returning; none of these pointers
        // escape this private owner queue or remain live across a suspension.
        let values = parameters.map { $0.map { strdup($0) } ?? nil }
        defer { values.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = values.map { $0.map { UnsafePointer<CChar>($0) } }
        let sent = pointers.withUnsafeBufferPointer { buffer in
            sql.withCString { PQsendQueryParams(connection, $0, Int32(parameters.count), nil, buffer.baseAddress, nil, nil, 0) }
        }
        guard sent == 1 else { close(error: connectionError()); return }
        guard PQsetSingleRowMode(connection) == 1 else {
            close(error: DatabaseError("libpq could not enable incremental result delivery.", connectionLost: true)); return
        }
        pumpQuery()
    }

    private var isUTF8: Bool {
        guard let connection, let encoding = PQparameterStatus(connection, "client_encoding") else { return false }
        return String(cString: encoding) == "UTF8"
    }

    private func encodingError() -> DatabaseError {
        DatabaseError("The session's client_encoding changed from UTF8. Reconnect before executing more SQL; db3 will not decode values using an unsupported encoding.")
    }

    private func pumpQuery(consumeInput: Bool = false) {
        guard let connection, let query else { return }
        // Cancellation drains independently of a suspended/slow consumer.
        guard query.deliveryID == nil || query.cancelRequested else { return }
        if query.complete { completeQueryIfPossible(); return }
        if consumeInput, PQconsumeInput(connection) != 1 { close(error: connectionError()); return }
        switch PQflush(connection) {
        case -1: close(error: connectionError()); return
        case 1: watchSocket(read: false)
        default: removeWriteWatch()
        }
        let turnStart = DispatchTime.now().uptimeNanoseconds
        var resultCount = 0
        while PQisBusy(connection) == 0 {
            guard let result = PQgetResult(connection) else {
                query.complete = true
                removeReadWatch(); removeWriteWatch()
                if !isUTF8, query.error == nil { query.error = encodingError() }
                deliverRemainingOrFinish()
                return
            }
            resultCount += 1
            let status = PQresultStatus(result)
            if status == PGRES_COPY_IN || status == PGRES_COPY_OUT || status == PGRES_COPY_BOTH {
                PQclear(result)
                close(error: DatabaseError("COPY transfer is not supported in this scaffold. The connection was closed to leave PostgreSQL in a safe protocol state; reconnect to continue.", connectionLost: true))
                return
            }
            if !isUTF8, query.error == nil { query.error = encodingError() }
            var columnsEvent: QueryEvent?
            switch status {
            case PGRES_SINGLE_TUPLE, PGRES_TUPLES_OK:
                if !query.cancelRequested, query.error == nil {
                    do {
                        if !query.columnsDelivered {
                            columnsEvent = .columns(try columns(result))
                            query.columnsDelivered = true
                        }
                        for rowIndex in 0..<PQntuples(result) {
                            let row = try decodeRow(result, rowIndex)
                            query.rows.append(row)
                            query.bytes += row.reduce(16) { $0 + $1.byteCount }
                            query.totalRows += 1
                        }
                    } catch { query.error = error }
                }
                if status == PGRES_TUPLES_OK { query.command = String(cString: PQcmdStatus(result)) }
            case PGRES_COMMAND_OK:
                query.command = String(cString: PQcmdStatus(result))
                if let count = PQcmdTuples(result), let changed = Int(String(cString: count)) { query.totalRows = changed }
            case PGRES_EMPTY_QUERY: query.command = "Empty query"
            case PGRES_FATAL_ERROR, PGRES_BAD_RESPONSE:
                if query.error == nil { query.error = resultError(result) }
            case PGRES_NONFATAL_ERROR:
                receiveNotice(result)
            default:
                if query.error == nil { query.error = DatabaseError("Unsupported PostgreSQL result status: \(PQresultStatus(result).rawValue).") }
            }
            PQclear(result)
            if PQstatus(connection) == CONNECTION_BAD { close(error: connectionError()); return }
            if let columnsEvent { deliver(columnsEvent); return }
            if query.error != nil && !query.cancelRequested && status != PGRES_FATAL_ERROR {
                // Decode/consumer failures stop the server as well as storage.
                startCancellation(); return
            }
            if !query.cancelRequested, query.rows.count >= 512 || query.bytes >= 256 * 1024 {
                deliverRows(); return
            }
            if resultCount >= 512 || DispatchTime.now().uptimeNanoseconds - turnStart >= 4_000_000 {
                if !query.cancelRequested, !query.rows.isEmpty { deliverRows() }
                else { queue.async { self.pumpQuery() } }
                return
            }
        }
        if !query.cancelRequested, !query.rows.isEmpty { schedulePartialBatch() }
        if !query.cancelRequested, !notices.isEmpty { deliverNotice(); return }
        watchSocket(read: true)
    }

    private func columns(_ result: OpaquePointer) throws -> [DatabaseColumn] {
        try (0..<PQnfields(result)).map { index in
            guard let name = PQfname(result, index), let decoded = String(validatingCString: name) else {
                throw DatabaseError("A PostgreSQL column name is not valid UTF-8.")
            }
            return DatabaseColumn(index: Int(index), name: decoded, typeOID: PQftype(result, index))
        }
    }

    private func decodeRow(_ result: OpaquePointer, _ row: Int32) throws -> DatabaseRow {
        try (0..<PQnfields(result)).map { column in
            if PQgetisnull(result, row, column) == 1 { return .null }
            let length = Int(PQgetlength(result, row, column))
            guard let bytes = PQgetvalue(result, row, column) else { return .text("") }
            let buffer = UnsafeRawBufferPointer(start: bytes, count: length)
            guard let text = String(bytes: buffer, encoding: .utf8) else {
                throw DatabaseError("A PostgreSQL value is not valid UTF-8. No replacement characters were inserted.")
            }
            return .text(text)
        }
    }

    private func deliverRows() {
        guard let query, !query.rows.isEmpty else { return }
        let rows = query.rows
        query.rows = []; query.bytes = 0
        deliver(.rows(RowBatch(rows: rows)))
    }

    private func deliverNotice() {
        guard !notices.isEmpty else { return }
        let notice = notices.removeFirst()
        noticeBytes -= notice.utf8.count
        deliver(.notice(notice))
    }

    private func deliver(_ event: QueryEvent) {
        guard let query, query.deliveryID == nil, !query.cancelRequested else { return }
        partialBatchDeadline?.cancel(); partialBatchDeadline = nil
        removeReadWatch()
        let id = query.id, deliveryID = UUID(), consumer = query.consumer
        query.deliveryID = deliveryID
        query.consumerTask = Task.detached(priority: .utility) { [weak self] in
            let result: Result<Void, any Error>
            do { try await consumer(event); result = .success(()) }
            catch { result = .failure(error) }
            guard let self else { return }
            self.queue.async { self.consumerFinished(id: id, deliveryID: deliveryID, result: result) }
        }
    }

    private func schedulePartialBatch() {
        guard partialBatchDeadline == nil, let query else { return }
        let id = query.id
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // A socket read often contains only a few dozen rows. Coalesce the next
        // ready chunks, but deliver a quiet/slow server's partial batch promptly.
        timer.schedule(deadline: .now() + .milliseconds(2), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.partialBatchDeadline?.cancel(); self.partialBatchDeadline = nil
            guard let query = self.query, query.id == id, query.deliveryID == nil, !query.cancelRequested else { return }
            self.deliverRows()
        }
        partialBatchDeadline = timer; timer.resume()
    }

    private func consumerFinished(id: UUID, deliveryID: UUID, result: Result<Void, any Error>) {
        guard let query, query.id == id, query.deliveryID == deliveryID else { return }
        query.deliveryID = nil; query.consumerTask = nil
        if case .failure(let error) = result, query.error == nil { query.error = error }
        if case .failure = result, !query.cancelRequested, !query.complete { startCancellation(); return }
        if query.complete { deliverRemainingOrFinish() }
        else { pumpQuery() }
    }

    private func deliverRemainingOrFinish() {
        guard let query, query.deliveryID == nil else { return }
        if !query.cancelRequested {
            if !query.rows.isEmpty { deliverRows(); return }
            if !notices.isEmpty { deliverNotice(); return }
        }
        completeQueryIfPossible()
    }

    private func completeQueryIfPossible() {
        guard let query, query.complete, query.deliveryID == nil, cancellation == nil else { return }
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        self.query = nil
        notices.removeAll(keepingCapacity: true); noticeBytes = 0
        if let error = query.error { query.continuation.resume(throwing: error) }
        else if query.cancelRequested { query.continuation.resume(throwing: CancellationError()) }
        else {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - query.started) / 1_000_000_000
            query.continuation.resume(returning: QuerySummary(command: query.command, rowCount: query.totalRows, transaction: currentTransactionState(), elapsed: elapsed))
        }
    }

    private func startCancellation() {
        guard let connection, let query, !query.cancelRequested else { return }
        query.cancelRequested = true
        partialBatchDeadline?.cancel(); partialBatchDeadline = nil
        query.consumerTask?.cancel()
        query.rows.removeAll(); query.bytes = 0
        // If the original protocol is already fully drained, there is nothing
        // to cancel. This also prevents a late click targeting the next query.
        if query.complete { completeQueryIfPossible(); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10)
        let queryID = query.id
        timer.setEventHandler { [weak self] in
            guard let self, self.query?.id == queryID else { return }
            self.close(error: DatabaseError("Cancellation recovery timed out. The session was closed; the server-side outcome may be uncertain.", connectionLost: true))
        }
        recoveryDeadline = timer; timer.resume()
        guard let cancellation = PQcancelCreate(connection) else {
            close(error: DatabaseError("Could not create a cancellation request. The session was closed; the server-side outcome may be uncertain.", connectionLost: true)); return
        }
        self.cancellation = cancellation
        guard PQcancelStatus(cancellation) != CONNECTION_BAD, PQcancelStart(cancellation) == 1 else {
            close(error: cancellationError()); return
        }
        watchCancellation(read: false)
        // Result consumption continues even while the cancel connection is
        // establishing, and even before the query has delivered its first row.
        pumpQuery()
    }

    private func pollCancellation() {
        guard let cancellation else { return }
        switch PQcancelPoll(cancellation) {
        case PGRES_POLLING_READING: watchCancellation(read: true)
        case PGRES_POLLING_WRITING: watchCancellation(read: false)
        case PGRES_POLLING_OK:
            clearCancellation()
            completeQueryIfPossible()
        case PGRES_POLLING_ACTIVE: queue.async { self.pollCancellation() }
        default: close(error: cancellationError())
        }
    }

    private func watchSocket(read: Bool) {
        guard let connection else { return }
        let socket = PQsocket(connection)
        guard socket >= 0 else { close(error: connectionError()); return }
        if connecting != nil { removeReadWatch(); removeWriteWatch() }
        if read {
            guard readWatch == nil else { return }
            readEpoch &+= 1
            let epoch = readEpoch
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, self.readEpoch == epoch else { return }
                self.removeReadWatch()
                if self.connecting != nil { self.pollConnection() }
                else { self.pumpQuery(consumeInput: true) }
            }
            readWatch = source; source.resume()
        } else {
            guard writeWatch == nil else { return }
            writeEpoch &+= 1
            let epoch = writeEpoch
            let source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, self.writeEpoch == epoch else { return }
                self.removeWriteWatch()
                if self.connecting != nil { self.pollConnection() }
                else { self.pumpQuery() }
            }
            writeWatch = source; source.resume()
        }
    }

    private func watchCancellation(read: Bool) {
        guard let cancellation else { return }
        cancelReadWatch?.cancel(); cancelReadWatch = nil
        cancelWriteWatch?.cancel(); cancelWriteWatch = nil
        cancelEpoch &+= 1
        let epoch = cancelEpoch
        let socket = PQcancelSocket(cancellation)
        guard socket >= 0 else { close(error: cancellationError()); return }
        let callback: @Sendable () -> Void = { [weak self] in
            guard let self, self.cancelEpoch == epoch else { return }
            self.cancelReadWatch?.cancel(); self.cancelReadWatch = nil
            self.cancelWriteWatch?.cancel(); self.cancelWriteWatch = nil
            self.cancelEpoch &+= 1
            self.pollCancellation()
        }
        if read {
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler(handler: callback)
            cancelReadWatch = source; source.resume()
        } else {
            let source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler(handler: callback)
            cancelWriteWatch = source; source.resume()
        }
    }

    private func removeReadWatch() { readEpoch &+= 1; readWatch?.cancel(); readWatch = nil }
    private func removeWriteWatch() { writeEpoch &+= 1; writeWatch?.cancel(); writeWatch = nil }

    private func clearCancellation() {
        cancelEpoch &+= 1
        cancelReadWatch?.cancel(); cancelReadWatch = nil
        cancelWriteWatch?.cancel(); cancelWriteWatch = nil
        if let cancellation { PQcancelFinish(cancellation) }
        cancellation = nil
    }

    private func receiveNotice(_ result: OpaquePointer) {
        dispatchPrecondition(condition: .onQueue(queue))
        // A server can emit arbitrarily many notices. Bound their queued count
        // and bytes; query rows are never dropped by this presentation policy.
        guard notices.count < 32, noticeBytes < 64 * 1024 else { return }
        let message = String(cString: PQresultErrorMessage(result))
        let bounded = String(message.prefix(4096))
        notices.append(bounded); noticeBytes += bounded.utf8.count
    }

    private func resultError(_ result: OpaquePointer) -> DatabaseError {
        let message = String(cString: PQresultErrorMessage(result)).trimmingCharacters(in: .whitespacesAndNewlines)
        let state = PQresultErrorField(result, 67).map { String(cString: $0) } // PG_DIAG_SQLSTATE
        return DatabaseError(message.isEmpty ? "PostgreSQL reported an error." : message, sqlState: state)
    }

    private func connectionError() -> DatabaseError {
        var message = connection.flatMap { PQerrorMessage($0) }.map { String(cString: $0) } ?? "PostgreSQL connection failed."
        var state: String?
        if connecting != nil, let connection {
            if PQconnectionNeedsPassword(connection) == 1 { state = "28000" }
            // The five-character server code is independent of the server's
            // message language. Do not infer auth failure just because a
            // password was used: database/TLS/config failures are distinct.
            if let field = message.range(of: #":[\t ]+(?=[0-9A-Z]*[0-9])[0-9A-Z]{5}: "#, options: .regularExpression) {
                let token = message[field].trimmingCharacters(in: CharacterSet(charactersIn: ": \t\n"))
                state = token
                message.replaceSubrange(field, with: ": ")
            }
            message = message.components(separatedBy: "\n").filter { !$0.hasPrefix("LOCATION:") }.joined(separator: "\n")
        }
        return DatabaseError(message.trimmingCharacters(in: .whitespacesAndNewlines), sqlState: state, connectionLost: true)
    }

    private func cancellationError() -> DatabaseError {
        let message = cancellation.flatMap { PQcancelErrorMessage($0) }.map { String(cString: $0) } ?? "Cancellation failed."
        return DatabaseError("\(message.trimmingCharacters(in: .whitespacesAndNewlines)) The session was closed; the server-side outcome may be uncertain.", connectionLost: true)
    }

    private func currentTransactionState() -> TransactionState {
        guard let connection, PQstatus(connection) == CONNECTION_OK else { return .unknown }
        switch PQtransactionStatus(connection) {
        case PQTRANS_IDLE: return .idle
        case PQTRANS_INTRANS: return .inTransaction
        case PQTRANS_INERROR: return .failed
        default: return .unknown
        }
    }

    private func close(error: any Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        removeReadWatch(); removeWriteWatch(); clearCancellation()
        deadline?.cancel(); deadline = nil
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        partialBatchDeadline?.cancel(); partialBatchDeadline = nil
        if let connection { PQfinish(connection) }
        connection = nil
        let attempt = connecting; connecting = nil
        let operation = query; query = nil
        operation?.consumerTask?.cancel()
        attempt?.continuation.resume(throwing: error)
        operation?.continuation.resume(throwing: error)
        notices.removeAll(keepingCapacity: false); noticeBytes = 0
    }
}

/// getaddrinfo is blocking. Its admission queue and active worker count are
/// bounded globally, and connection deadlines run independently of DNS work.
private final class HostResolver: @unchecked Sendable {
    static let shared = HostResolver()
    private let admission = DispatchQueue(label: "app.db3.postgres.dns-admission", qos: .utility)
    private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.db3.postgres.dns"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var admitted = 0

    func resolve(_ host: String, completion: @escaping @Sendable (Result<[String], DatabaseError>) -> Void) {
        admission.async {
            if host.hasPrefix("/") { completion(.success([])); return }
            guard self.admitted < 8 else {
                completion(.failure(DatabaseError("The hostname resolver is busy. Try connecting again shortly."))); return
            }
            self.admitted += 1
            self.workers.addOperation {
                let result = Self.lookup(host)
                self.admission.async {
                    self.admitted -= 1
                    completion(result)
                }
            }
        }
    }

    private static func lookup(_ host: String) -> Result<[String], DatabaseError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var first: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &first)
        guard code == 0 else {
            return .failure(DatabaseError("Could not resolve \(host): \(String(cString: gai_strerror(code))).", connectionLost: true))
        }
        defer { if let first { freeaddrinfo(first) } }
        var addresses: [String] = []
        var current = first
        while let item = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if !addresses.contains(address) { addresses.append(address) }
            }
            current = item.pointee.ai_next
        }
        guard !addresses.isEmpty else { return .failure(DatabaseError("No usable network address was found for \(host).", connectionLost: true)) }
        return .success(addresses)
    }
}
