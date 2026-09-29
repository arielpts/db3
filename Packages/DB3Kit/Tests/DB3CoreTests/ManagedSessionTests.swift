import Foundation
import XCTest
import DB3Core
import DB3Postgres

final class TransactionClassificationTests: XCTestCase {
    func testOnlyLeadingUnquotedKeywordsAreControls() throws {
        let fixtures: [(String, SQLTransactionControl)] = [
            ("-- comment\n/* outer /* nested */ end */ bEgIn", .begin),
            ("START /* options */ TRANSACTION READ ONLY", .begin),
            ("COMMIT WORK AND CHAIN", .commit), ("END TRANSACTION AND NO CHAIN", .commit),
            ("; /* leading empty statement */ ; COMMIT", .commit),
            ("ROLLBACK TRANSACTION TO SAVEPOINT x", .rollbackToSavepoint),
            ("ABORT WORK AND CHAIN", .rollback), ("SAVEPOINT x", .savepoint),
            ("RELEASE /* savepoint */ SAVEPOINT x", .releaseSavepoint),
            ("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", .setTransaction),
            ("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY", .setTransaction),
            ("PREPARE TRANSACTION 'id'", .unsupported),
            ("COMMIT /* comment */ PREPARED 'id'", .unsupported),
            ("ROLLBACK PREPARED 'id'", .unsupported),
            ("PREPARE ordinary_query AS SELECT 1", .ordinary),
            ("SELECT 'COMMIT', E'ROLLBACK', $$ BEGIN $$", .ordinary),
            ("SELECT \"COMMIT\" FROM data", .ordinary),
            ("DO $body$ BEGIN RAISE NOTICE 'COMMIT'; END $body$", .ordinary),
            ("\"COMMIT\"", .ordinary), ("'COMMIT'", .ordinary), ("$a$COMMIT$a$", .ordinary),
            ("COMMITMENT", .ordinary), ("beginning", .ordinary), ("COMMIT$identifier", .ordinary),
            ("SELECT 1; COMMIT", .ordinary)
        ]
        for (sql, expected) in fixtures { XCTAssertEqual(try SQLTransactionControl.classify(sql), expected, sql) }
        XCTAssertThrowsError(try SQLTransactionControl.classify("/* unfinished"))
    }

    func testLegacyProfilesRemainUnclassifiedAndColumnsHaveNoGuessedProvenance() throws {
        let profile = ConnectionProfile(environment: .production)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data).environment, .production)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "environment")
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: legacy)).environment, .unknown)
        let column = try JSONDecoder().decode(DatabaseColumn.self, from: Data(#"{"index":0,"name":"value","typeOID":25}"#.utf8))
        XCTAssertNil(column.relationOID)
        XCTAssertNil(column.attributeNumber)
        XCTAssertEqual(TransactionState.idle.title, "No transaction")
    }
}

@MainActor
final class ManagedSessionTests: XCTestCase {
    func testManualSelectLazilyBeginsOnceAndReusesTransaction() async throws {
        let raw = TransactionMockSession()
        let managed = ManagedSession(session: raw, environment: .production)
        let initialState = await managed.transactionState()
        XCTAssertEqual(initialState, .idle)
        _ = try await managed.run(sql: "SELECT 1", mode: .manual) { _ in }
        _ = try await managed.run(sql: "SELECT 2", mode: .manual) { _ in }
        let commands = await raw.commands
        XCTAssertEqual(commands, ["BEGIN", "SELECT 1", "SELECT 2"])
        let began = await managed.transactionBeganAt
        XCTAssertNotNil(began)
        _ = try await managed.commit()
        let ended = await managed.transactionBeganAt
        XCTAssertNil(ended)
    }

    func testExplicitEditingStartsWritableTransactionDespiteReadOnlyDefault() async throws {
        let raw = TransactionMockSession(defaultReadOnly: true)
        let managed = ManagedSession(session: raw, environment: .production)
        _ = try await managed.run(sql: "SELECT value FROM editable_table", mode: .manual, requiresWritableTransaction: true) { _ in }
        let commands = await raw.commands, readOnly = await raw.readOnly
        XCTAssertEqual(commands, ["BEGIN READ WRITE", "SELECT value FROM editable_table"])
        XCTAssertFalse(readOnly)
        let state = await managed.transactionState()
        XCTAssertEqual(state, .inTransaction)
    }

    func testExplicitEditingDoesNotChangeExistingReadOnlyTransaction() async throws {
        let raw = TransactionMockSession()
        let managed = ManagedSession(session: raw, environment: .production)
        _ = try await managed.run(sql: "BEGIN READ ONLY", mode: .manual) { _ in }
        _ = try await managed.run(sql: "SELECT value FROM editable_table", mode: .manual, requiresWritableTransaction: true) { _ in }
        let commands = await raw.commands, readOnly = await raw.readOnly
        XCTAssertEqual(commands, ["BEGIN READ ONLY", "SELECT value FROM editable_table"])
        XCTAssertTrue(readOnly)
    }

    func testOrdinaryQueryPreservesReadOnlyDefaultAndEditHonorsServerRefusal() async throws {
        let raw = TransactionMockSession(defaultReadOnly: true)
        let managed = ManagedSession(session: raw, environment: .production)
        _ = try await managed.run(sql: "SELECT 1", mode: .manual) { _ in }
        let commands = await raw.commands, readOnly = await raw.readOnly
        XCTAssertEqual(commands, ["BEGIN", "SELECT 1"])
        XCTAssertTrue(readOnly)

        let replica = TransactionMockSession(defaultReadOnly: true, rejectReadWrite: true)
        let replicaOwner = ManagedSession(session: replica, environment: .production)
        do {
            _ = try await replicaOwner.run(sql: "SELECT value FROM editable_table", mode: .manual, requiresWritableTransaction: true) { _ in }
            XCTFail("A replica must reject a write transaction before the editable snapshot loads")
        } catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "0A000") }
        let replicaCommands = await replica.commands
        XCTAssertEqual(replicaCommands, ["BEGIN READ WRITE"])
    }

    func testAutoRequiresExplicitDevelopmentEveryRun() async throws {
        for environment in [ConnectionEnvironment.unknown, .production] {
            let raw = TransactionMockSession()
            let managed = ManagedSession(session: raw, environment: environment)
            do { _ = try await managed.run(sql: "SELECT 1", mode: .auto) { _ in }; XCTFail("Unsafe Auto request") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Development")) }
            let commands = await raw.commands
            XCTAssertTrue(commands.isEmpty)
        }
        let raw = TransactionMockSession()
        let own = ManagedSession(session: raw, environment: .development)
        try await own.validateModeChange(to: .auto)
        _ = try await own.run(sql: "SELECT 1", mode: .auto) { _ in }
        let commands = await raw.commands
        XCTAssertEqual(commands, ["SELECT 1"])
    }

    func testFailedTransactionRequiresRecoveryAndCommitCannotReportRollbackAsSuccess() async throws {
        let raw = TransactionMockSession()
        let owner = ManagedSession(session: raw, environment: .unknown)
        do { _ = try await owner.run(sql: "BAD", mode: .manual) { _ in }; XCTFail("Expected server error") } catch { }
        do { _ = try await owner.run(sql: "SELECT 1", mode: .manual) { _ in }; XCTFail("Failed transaction must block Run") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Roll back")) }
        do { _ = try await owner.commit(); XCTFail("COMMIT-as-ROLLBACK must not be success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rolled back")) }
        let commands = await raw.commands
        XCTAssertEqual(commands, ["BEGIN", "BAD", "COMMIT"])
        let state = await owner.transactionState()
        XCTAssertEqual(state, .idle)
    }

    func testExplicitControlsAndChainUseServerStateWithoutImplicitCommit() async throws {
        let raw = TransactionMockSession()
        let managed = ManagedSession(session: raw, environment: .production)
        _ = try await managed.run(sql: "/* begin */ START TRANSACTION", mode: .manual) { _ in }
        do { _ = try await managed.run(sql: "BEGIN", mode: .manual) { _ in }; XCTFail("No nested BEGIN") } catch { }
        do { try await managed.validateModeChange(to: .manual); XCTFail("Open transaction must be resolved") } catch { }
        _ = try await managed.run(sql: "COMMIT WORK AND CHAIN", mode: .manual) { _ in }
        _ = try await managed.run(sql: "SELECT 7", mode: .manual) { _ in }
        _ = try await managed.run(sql: "ROLLBACK TRANSACTION AND NO CHAIN", mode: .manual) { _ in }
        let commands = await raw.commands
        XCTAssertEqual(commands, ["/* begin */ START TRANSACTION", "COMMIT WORK AND CHAIN", "SELECT 7", "ROLLBACK TRANSACTION AND NO CHAIN"])
        let state = await managed.transactionState()
        XCTAssertEqual(state, .idle)
    }

    func testTwoPhaseCommitIsRejectedBeforeAnyCommand() async throws {
        for sql in ["PREPARE TRANSACTION 'x'", "COMMIT PREPARED 'x'", "ROLLBACK PREPARED 'x'"] {
            let raw = TransactionMockSession()
            let owner = ManagedSession(session: raw, environment: .production)
            do { _ = try await owner.run(sql: sql, mode: .manual) { _ in }; XCTFail("Unsupported 2PC") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Two-phase")) }
            let commands = await raw.commands
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testUnknownCommitAcknowledgementIsExplicitAndNeverReplayed() async throws {
        let raw = TransactionMockSession(commitFailure: true)
        let managed = ManagedSession(session: raw, environment: .development)
        _ = try await managed.run(sql: "UPDATE synthetic SET value = 2", mode: .manual) { _ in }
        do { _ = try await managed.commit(); XCTFail("Unknown outcome") }
        catch let error as DatabaseError {
            XCTAssertTrue(error.commitOutcomeUnknown)
            XCTAssertTrue(error.connectionLost)
        }
        let commands = await raw.commands
        XCTAssertEqual(commands, ["BEGIN", "UPDATE synthetic SET value = 2", "COMMIT"])
    }

    func testLeasePreventsInterleavingAcrossAwaitsAndReleasesAfterFailure() async throws {
        let raw = TransactionMockSession()
        let managed = ManagedSession(session: raw, environment: .development)
        let first = Task {
            try await managed.withExclusiveOperation { session in
                _ = try await session.execute(sql: "PAUSE") { _ in }
                _ = try await session.execute(sql: "SECOND") { _ in }
            }
        }
        await raw.waitForPause()
        do { _ = try await managed.run(sql: "INTERLEAVED", mode: .auto) { _ in }; XCTFail("Lease must reject another operation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("operation in progress")) }
        await raw.resume()
        try await first.value
        do { try await managed.withExclusiveOperation { _ in throw DatabaseError("intentional") } } catch { }
        _ = try await managed.run(sql: "AFTER", mode: .auto) { _ in }
        let commands = await raw.commands
        XCTAssertEqual(commands, ["PAUSE", "SECOND", "AFTER"])
    }

    func testLegacySessionDefaultNeverInterpolatesParameters() async throws {
        let raw: any DatabaseSession = TransactionMockSession()
        _ = try await raw.execute(sql: "SELECT 1", parameters: []) { _ in }
        do { _ = try await raw.execute(sql: "SELECT $1", parameters: ["malicious'; COMMIT;"]) { _ in }; XCTFail("No unsupported substitution") }
        catch { XCTAssertTrue(error.localizedDescription.contains("bound SQL parameters")) }
    }

    func testEnvironmentCanTightenSynchronouslyButNeverLoosen() async throws {
        let raw = TransactionMockSession()
        let managed = ManagedSession(session: raw, environment: .development)
        try managed.authorizeAutoCommit()
        managed.restrictEnvironment(to: .unknown)
        XCTAssertEqual(managed.environment, .development, "Original connected context remains immutable.")
        XCTAssertEqual(managed.effectiveEnvironment, .unknown)
        XCTAssertThrowsError(try managed.authorizeAutoCommit())
        managed.restrictEnvironment(to: .development)
        XCTAssertEqual(managed.effectiveEnvironment, .unknown)
        managed.restrictEnvironment(to: .production)
        managed.restrictEnvironment(to: .unknown)
        XCTAssertEqual(managed.effectiveEnvironment, .production)
        do { _ = try await managed.run(sql: "SELECT 1", mode: .auto) { _ in }; XCTFail("A changed profile cannot keep using Auto") } catch { }
        let commands = await raw.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testTighteningWhileExclusiveOperationAwaitsPreventsAutomaticCommit() async throws {
        let raw = TransactionMockSession()
        let managed = ManagedSession(session: raw, environment: .development)
        let applying = Task {
            try await managed.withExclusiveOperation { session in
                _ = try await session.execute(sql: "BEGIN") { _ in }
                _ = try await session.execute(sql: "PAUSE") { _ in }
                try managed.authorizeAutoCommit()
                return try await session.execute(sql: "COMMIT") { _ in }
            }
        }
        await raw.waitForPause()
        // Synchronous restriction does not need the occupied operation lease.
        managed.restrictEnvironment(to: .production)
        await raw.resume()
        do { _ = try await applying.value; XCTFail("Automatic commit after reclassification") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Manual")) }
        let commands = await raw.commands
        XCTAssertEqual(commands, ["BEGIN", "PAUSE"])
        _ = try await managed.rollback()
    }
}

private actor TransactionMockSession: DatabaseSession {
    private var state: TransactionState = .idle
    private(set) var commands: [String] = []
    private let commitFailure: Bool
    private let defaultReadOnly: Bool
    private let rejectReadWrite: Bool
    private(set) var readOnly = false
    private var paused = false
    private var pause: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    init(commitFailure: Bool = false, defaultReadOnly: Bool = false, rejectReadWrite: Bool = false) {
        self.commitFailure = commitFailure; self.defaultReadOnly = defaultReadOnly; self.rejectReadWrite = rejectReadWrite
    }
    func connect(profile: ConnectionProfile, password: String) async throws -> SessionInfo { SessionInfo(serverVersion: "test", backendPID: 0) }
    func transactionState() async -> TransactionState { state }
    func cancel() async { resume() }
    func disconnect() async { state = .unknown; resume() }
    func waitForPause() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }
    func resume() { pause?.resume(); pause = nil }
    func execute(sql: String, onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        commands.append(sql)
        if sql == "PAUSE" {
            paused = true
            pauseWaiters.forEach { $0.resume() }; pauseWaiters.removeAll()
            await withCheckedContinuation { pause = $0 }
        }
        let control = try SQLTransactionControl.classify(sql)
        var command = "SELECT 1"
        switch control {
        case .begin:
            if sql.contains("READ WRITE"), rejectReadWrite { throw DatabaseError("cannot set transaction read-write mode during recovery", sqlState: "0A000") }
            readOnly = sql.contains("READ WRITE") ? false : sql.contains("READ ONLY") || defaultReadOnly
            state = .inTransaction; command = "BEGIN"
        case .commit:
            if commitFailure { state = .unknown; throw DatabaseError("synthetic connection loss", connectionLost: true) }
            command = state == .failed ? "ROLLBACK" : "COMMIT"
            state = sql.hasSuffix("AND CHAIN") ? .inTransaction : .idle
        case .rollback: state = sql.hasSuffix("AND CHAIN") ? .inTransaction : .idle; command = "ROLLBACK"
        case .rollbackToSavepoint: state = .inTransaction; command = "ROLLBACK"
        default: break
        }
        if sql == "BAD" { state = .failed; throw DatabaseError("synthetic invalid statement", sqlState: "42601") }
        return QuerySummary(command: command, rowCount: 0, transaction: state, elapsed: 0)
    }
}

@MainActor
final class ManagedPostgresTests: XCTestCase {
    func testManualStateCommitChainFailedCommitAndSourceColumnIdentity() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["DB3_TEST_PORT"], let port = Int(value) else { throw XCTSkip("Disposable PostgreSQL fixture is not running.") }
        let profile = ConnectionProfile(host: environment["DB3_TEST_HOST"] ?? "127.0.0.1", port: port,
                                        database: environment["DB3_TEST_DATABASE"] ?? "postgres",
                                        username: environment["DB3_TEST_USER"] ?? NSUserName(), tls: .disable, environment: .production)
        let raw = PostgresSession()
        _ = try await raw.connect(profile: profile, password: environment["DB3_TEST_PASSWORD"] ?? "")
        let owner = ManagedSession(session: raw, environment: profile.environment)
        do {
            let first = try await owner.run(sql: "SELECT 1", mode: .manual) { _ in }
            XCTAssertEqual(first.transaction, .inTransaction)
            _ = try await owner.run(sql: "CREATE TEMP TABLE db3_edit_provenance (id int PRIMARY KEY, value text)", mode: .manual) { _ in }
            let columns = TransactionColumns()
            _ = try await owner.run(sql: "SELECT id, value, 1 AS expression FROM db3_edit_provenance", mode: .manual) { event in await columns.consume(event) }
            let values = await columns.columns
            XCTAssertEqual(values.count, 3)
            XCTAssertNotNil(values[0].relationOID)
            XCTAssertEqual(values[0].attributeNumber, 1)
            XCTAssertEqual(values[1].attributeNumber, 2)
            XCTAssertNil(values[2].relationOID)
            XCTAssertNil(values[2].attributeNumber)
            let chained = try await owner.run(sql: "COMMIT /* continuation */ AND CHAIN", mode: .manual) { _ in }
            XCTAssertEqual(chained.transaction, .inTransaction)
            do { _ = try await owner.run(sql: "SELECT 1/0", mode: .manual) { _ in }; XCTFail("Expected division error") } catch { }
            do { _ = try await owner.commit(); XCTFail("Failed transaction COMMIT reports ROLLBACK") }
            catch { XCTAssertTrue(error.localizedDescription.contains("rolled back")) }
            let state = await owner.transactionState()
            XCTAssertEqual(state, .idle)
        } catch {
            await raw.disconnect()
            throw error
        }
        await raw.disconnect()
    }
}

private actor TransactionColumns {
    private(set) var columns: [DatabaseColumn] = []
    func consume(_ event: QueryEvent) { if case .columns(let value) = event { columns = value } }
}
