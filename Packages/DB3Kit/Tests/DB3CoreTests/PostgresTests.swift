import Foundation
import XCTest
import DB3Core
import DB3Postgres

/// Set DB3_TEST_PORT to run against a disposable local PostgreSQL server.
/// These tests intentionally exercise protocol state after failures, not only
/// the successful decoding path. No network is used when that variable is absent.
@MainActor
final class PostgresTests: XCTestCase {
    private func settings() throws -> (ConnectionProfile, String) {
        let env = ProcessInfo.processInfo.environment
        guard let portValue = env["DB3_TEST_PORT"], let port = Int(portValue) else {
            throw XCTSkip("Set DB3_TEST_PORT to run PostgreSQL integration tests.")
        }
        return (ConnectionProfile(
            host: env["DB3_TEST_HOST"] ?? "127.0.0.1", port: port,
            database: env["DB3_TEST_DATABASE"] ?? "postgres",
            username: env["DB3_TEST_USER"] ?? NSUserName(), tls: .disable
        ), env["DB3_TEST_PASSWORD"] ?? "")
    }

    private func connected() async throws -> PostgresSession {
        let (profile, password) = try settings()
        let session = PostgresSession()
        let info = try await session.connect(profile: profile, password: password)
        XCTAssertGreaterThan(info.backendPID, 0)
        XCTAssertFalse(info.serverVersion.isEmpty)
        return session
    }

    private func run(_ sql: String, on session: PostgresSession) async throws -> QuerySummary {
        try await session.execute(sql: sql) { _ in }
    }

    func testDisconnectedAndInvalidSettingsFailWithoutNetwork() async {
        let session = PostgresSession()
        do {
            _ = try await run("SELECT 1", on: session)
            XCTFail("A disconnected session must reject SQL.")
        } catch let error as DatabaseError { XCTAssertTrue(error.connectionLost) }
        catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await session.connect(profile: ConnectionProfile(port: 0), password: "")
            XCTFail("An invalid port must be rejected.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("invalid")) }
        let transaction = await session.transactionState()
        XCTAssertEqual(transaction, .unknown)
        await session.disconnect()
    }

    func testConnectionURLUsesParsedDatabaseAndUsername() async throws {
        let (profile, password) = try settings()
        let url = PostgresConnectionURL.string(from: profile, password: password)
        let parsed = try PostgresConnectionURL.parse(url)
        let session = PostgresSession()
        _ = try await session.connect(profile: parsed.profile, password: parsed.password ?? "")
        do {
            let collector = PostgresCollector()
            _ = try await session.execute(sql: "SELECT current_database(), current_user") { event in
                await collector.add(event)
            }
            let snapshot = await collector.snapshot()
            XCTAssertEqual(snapshot.rows, [[.text(profile.database), .text(profile.username)]])
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    func testExactTypesNullsUnicodeAndEmptyResult() async throws {
        let session = try await connected()
        let collector = PostgresCollector()
        let summary = try await session.execute(sql: """
            SELECT NULL::text AS absent, ''::text AS empty,
                   123456789012345678901234567890.123456789::numeric AS precise,
                   'ação 🐘'::text AS unicode, decode('00ff', 'hex') AS bytes,
                   ARRAY[1,2,3] AS numbers, '{"a":1}'::jsonb AS document
            """) { event in await collector.add(event) }
        let snapshot = await collector.snapshot()
        XCTAssertEqual(summary.rowCount, 1)
        XCTAssertEqual(snapshot.columns.map(\.typeOID), [25, 25, 1700, 25, 17, 1007, 3802])
        XCTAssertEqual(snapshot.rows.first, [.null, .text(""), .text("123456789012345678901234567890.123456789"), .text("ação 🐘"), .text("\\x00ff"), .text("{1,2,3}"), .text("{\"a\": 1}")])
        let empty = PostgresCollector()
        let emptySummary = try await session.execute(sql: "SELECT 1 AS present WHERE false") { event in await empty.add(event) }
        let emptySnapshot = await empty.snapshot()
        XCTAssertEqual(emptySummary.rowCount, 0)
        XCTAssertEqual(emptySnapshot.columns.first?.name, "present")
        await session.disconnect()
    }

    func testMultipleStatementsRejectedWithoutPartialExecution() async throws {
        let session = try await connected()
        do {
            _ = try await run("CREATE TEMP TABLE db3_must_not_exist(id int); SELECT 1", on: session)
            XCTFail("Extended protocol must reject multiple statements.")
        } catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "42601") }
        let rows = PostgresCollector()
        _ = try await session.execute(sql: "SELECT to_regclass('pg_temp.db3_must_not_exist')") { event in await rows.add(event) }
        let snapshot = await rows.snapshot()
        XCTAssertEqual(snapshot.rows, [[.null]])
        _ = try await run("SELECT 42", on: session)
        await session.disconnect()
    }

    func testCancelBeforeFirstRowAndExecuteAgain() async throws {
        let session = try await connected()
        let collector = PostgresCollector()
        let running = Task {
            try await session.execute(sql: "SELECT pg_sleep(30)") { event in await collector.add(event) }
        }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        await session.cancel()
        do { _ = try await running.value; XCTFail("The sleeping query must be cancelled.") }
        catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "57014") }
        catch is CancellationError { /* Task cancellation can win the race. */ }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.total, 0)
        let summary = try await run("SELECT 42", on: session)
        XCTAssertEqual(summary.rowCount, 1)
        XCTAssertEqual(summary.transaction, .idle)
        await session.disconnect()
    }

    func testFailedTransactionRequiresRollback() async throws {
        let session = try await connected()
        let begin = try await run("BEGIN", on: session)
        XCTAssertEqual(begin.transaction, .inTransaction)
        do { _ = try await run("SELECT 1/0", on: session); XCTFail("Division must fail.") }
        catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "22012") }
        let state = await session.transactionState()
        XCTAssertEqual(state, .failed)
        do { _ = try await run("SELECT 1", on: session); XCTFail("A failed transaction requires rollback.") }
        catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "25P02") }
        let rollback = try await run("ROLLBACK", on: session)
        XCTAssertEqual(rollback.transaction, .idle)
        _ = try await run("SELECT 1", on: session)
        await session.disconnect()
    }

    func testCancellationInTransactionAndLateCancelFence() async throws {
        let session = try await connected()
        _ = try await run("BEGIN", on: session)
        let sleeping = Task { try await run("SELECT pg_sleep(30)", on: session) }
        try await Task.sleep(for: .milliseconds(100))
        await session.cancel()
        do { _ = try await sleeping.value; XCTFail("The transaction query must be cancelled.") }
        catch { }
        let state = await session.transactionState()
        XCTAssertEqual(state, .failed)
        _ = try await run("ROLLBACK", on: session)
        for _ in 0..<12 {
            let racing = Task { try await run("SELECT pg_sleep(0.005)", on: session) }
            try await Task.sleep(for: .milliseconds(3))
            await session.cancel()
            _ = try? await racing.value
            // Completion is gated on both the original protocol drain and
            // disposal of the cancel connection. No cancellation may spill
            // into this next statement.
            let next = try await run("SELECT 42", on: session)
            XCTAssertEqual(next.rowCount, 1)
        }
        await session.cancel() // An idle cancellation is a no-op.
        _ = try await run("SELECT 1", on: session)
        await session.disconnect()
    }

    func testDisconnectWhileQueryIsBusy() async throws {
        let session = try await connected()
        let running = Task { try await run("SELECT pg_sleep(30)", on: session) }
        try await Task.sleep(for: .milliseconds(50))
        await session.disconnect()
        do { _ = try await running.value; XCTFail("Closing a busy worksheet must settle its query.") }
        catch let error as DatabaseError { XCTAssertTrue(error.connectionLost) }
        let transaction = await session.transactionState()
        XCTAssertEqual(transaction, .unknown)
    }

    func testMillionRowsWithSlowConsumerUsesBoundedBatches() async throws {
        let session = try await connected()
        let stats = PostgresCollector(retainRows: false)
        let result = try await session.execute(sql: "SELECT i, repeat('x', 240) AS payload FROM generate_series(1, 1000000) AS i") { event in
            await stats.add(event)
            if case .rows = event { try await Task.sleep(for: .milliseconds(1)) }
        }
        let snapshot = await stats.snapshot()
        XCTAssertEqual(result.rowCount, 1_000_000)
        XCTAssertEqual(snapshot.total, 1_000_000)
        XCTAssertLessThanOrEqual(snapshot.maxBatchRows, 512)
        XCTAssertLessThanOrEqual(snapshot.maxBatchBytes, 256 * 1024 + 512)
        XCTAssertGreaterThan(snapshot.batchCount, 1_900)
        await session.disconnect()
    }

    func testConsumerFailureCancelsAndRecovers() async throws {
        let session = try await connected()
        do {
            _ = try await session.execute(sql: "SELECT i FROM generate_series(1, 1000000) AS i") { event in
                if case .rows = event { throw PostgresConsumerFailure.quota }
            }
            XCTFail("A consumer error must propagate.")
        } catch PostgresConsumerFailure.quota { }
        _ = try await run("SELECT 9", on: session)
        await session.disconnect()
    }

    func testCancellationWhileConsumerIsSuspendedAndConcurrentExecuteRejected() async throws {
        let session = try await connected()
        let signal = PostgresSignal()
        let running = Task {
            try await session.execute(sql: "SELECT i FROM generate_series(1, 1000000) AS i") { event in
                if case .rows = event {
                    await signal.fire()
                    try await Task.sleep(for: .seconds(30))
                }
            }
        }
        await signal.wait()
        do { _ = try await run("SELECT 1", on: session); XCTFail("Overlapping commands must fail.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("progress")) }
        running.cancel()
        do { _ = try await running.value; XCTFail("Task cancellation must stop the query.") }
        catch { /* The transport and the consumer can race to report cancellation. */ }
        _ = try await run("SELECT 1", on: session)
        await session.disconnect()
    }

    func testUnsupportedCopyClosesSession() async throws {
        for sql in ["COPY (SELECT 1) TO STDOUT", "COPY pg_temp.db3_copy FROM STDIN"] {
            let session = try await connected()
            if sql.contains("FROM STDIN") { _ = try await run("CREATE TEMP TABLE db3_copy(id int)", on: session) }
            do { _ = try await run(sql, on: session); XCTFail("COPY requires a dedicated transfer flow.") }
            catch let error as DatabaseError {
                XCTAssertTrue(error.connectionLost)
                XCTAssertTrue(error.message.contains("COPY"))
            }
            let transaction = await session.transactionState()
            XCTAssertEqual(transaction, .unknown)
            await session.disconnect()
        }
    }

    func testEncodingChangesSuspendCommandsUntilReconnect() async throws {
        let session = try await connected()
        do { _ = try await run("SET client_encoding = LATIN1", on: session); XCTFail("Unsupported encoding must be visible.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("encoding")) }
        do { _ = try await run("SELECT 'ação'", on: session); XCTFail("SQL must not be sent using the wrong encoding.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("encoding")) }
        let (profile, password) = try settings()
        _ = try await session.connect(profile: profile, password: password)
        _ = try await run("SELECT 'ação'", on: session)
        await session.disconnect()
    }

    func testNetworkLossDoesNotReportReadyOrReplaySQL() async throws {
        let (profile, password) = try settings()
        let session = PostgresSession()
        let info = try await session.connect(profile: profile, password: password)
        let admin = try await connected()
        let running = Task { try await run("SELECT pg_sleep(30)", on: session) }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await run("SELECT pg_terminate_backend(\(info.backendPID))", on: admin)
        do { _ = try await running.value; XCTFail("A terminated backend must fail the query.") }
        catch let error as DatabaseError { XCTAssertTrue(error.connectionLost || error.sqlState == "57P01") }
        let transaction = await session.transactionState()
        XCTAssertEqual(transaction, .unknown)
        await session.disconnect(); await admin.disconnect()
    }

    func testOversizedValuePreservedWithoutPretendingItFitsBatchTarget() async throws {
        let session = try await connected()
        let collector = PostgresCollector()
        _ = try await session.execute(sql: "SELECT repeat('x', 1048576)") { event in await collector.add(event) }
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.rows.first?.first?.displayText.utf8.count, 1_048_576)
        XCTAssertGreaterThan(snapshot.maxBatchBytes, 256 * 1024)
        await session.disconnect()
    }

    func testTLSRequiredRejectsNonTLSServerFixture() async throws {
        guard ProcessInfo.processInfo.environment["DB3_TEST_EXPECT_TLS_FAILURE"] == "1" else {
            throw XCTSkip("Set DB3_TEST_EXPECT_TLS_FAILURE=1 for the local non-TLS fixture.")
        }
        var (profile, password) = try settings()
        profile.tls = .verifyFull
        let session = PostgresSession()
        do { _ = try await session.connect(profile: profile, password: password); XCTFail("A non-TLS server must not pass verify-full.") }
        catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("ssl") || error.localizedDescription.localizedCaseInsensitiveContains("certificate")) }
        await session.disconnect()
    }

    func testTLSCertificateAndHostnameValidation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portValue = env["DB3_TEST_TLS_PORT"], let port = Int(portValue),
              let root = env["DB3_TEST_TLS_CA"] else {
            throw XCTSkip("Set DB3_TEST_TLS_PORT and DB3_TEST_TLS_CA for a self-signed TLS fixture with DNS:localhost and no IP SAN.")
        }
        var (profile, password) = try settings()
        profile.port = port
        profile.host = "localhost"
        profile.tls = .verifyFull
        profile.rootCertificate = root
        let secure = PostgresSession()
        _ = try await secure.connect(profile: profile, password: password)
        let collector = PostgresCollector()
        _ = try await secure.execute(sql: "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()") { event in
            await collector.add(event)
        }
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.rows, [[.text("t")]])
        let sleeping = Task { try await run("SELECT pg_sleep(30)", on: secure) }
        try await Task.sleep(for: .milliseconds(50))
        await secure.cancel()
        do { _ = try await sleeping.value; XCTFail("Cancellation must also work over the verified TLS cancel connection.") }
        catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "57014") }
        catch is CancellationError { }
        _ = try await run("SELECT 1", on: secure)
        await secure.disconnect()

        profile.host = "127.0.0.1"
        let mismatch = PostgresSession()
        do {
            _ = try await mismatch.connect(profile: profile, password: password)
            XCTFail("A certificate for localhost must not verify for 127.0.0.1.")
        } catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("certificate")) }
        await mismatch.disconnect()

        profile.host = "localhost"
        profile.rootCertificate = ""
        let untrusted = PostgresSession()
        do {
            _ = try await untrusted.connect(profile: profile, password: password)
            XCTFail("The macOS root bundle must not trust the fixture's self-signed certificate.")
        } catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("certificate")) }
        await untrusted.disconnect()
    }
}

private enum PostgresConsumerFailure: Error { case quota }

private actor PostgresCollector {
    struct Snapshot: Sendable {
        var columns: [DatabaseColumn] = []
        var rows: [DatabaseRow] = []
        var total = 0
        var maxBatchRows = 0
        var maxBatchBytes = 0
        var batchCount = 0
    }
    private var value = Snapshot()
    private let retainRows: Bool
    init(retainRows: Bool = true) { self.retainRows = retainRows }
    func add(_ event: QueryEvent) {
        switch event {
        case .columns(let columns): value.columns = columns
        case .rows(let batch):
            value.total += batch.rows.count
            value.maxBatchRows = max(value.maxBatchRows, batch.rows.count)
            value.maxBatchBytes = max(value.maxBatchBytes, batch.byteCount)
            value.batchCount += 1
            if retainRows { value.rows += batch.rows }
        case .notice: break
        }
    }
    func snapshot() -> Snapshot { value }
}

private actor PostgresSignal {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func fire() { fired = true; waiter?.resume(); waiter = nil }
    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
