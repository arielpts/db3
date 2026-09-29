import Foundation
import XCTest
import DB3Core
import DB3Postgres

@MainActor
final class PostgresTransactionAccessTests: XCTestCase {
    func testWritableTransactionIsAcceptedWithoutChangingSettings() async throws {
        let session = TransactionAccessMockSession(values: [.text("off"), .text("on"), .text("false")])
        try await PostgresTransactionAccess.requireWritable(on: session)
        let commands = await session.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].hasPrefix("SELECT "))
    }

    func testReadOnlyTransactionReportsRecoveryStepsWithoutWriting() async throws {
        for (values, reason) in [
            (["on", "off", "false"], "reload Edit Table Data"),
            (["on", "on", "false"], "defaults to read-only"),
            (["on", "off", "true"], "writable primary")
        ] {
            let session = TransactionAccessMockSession(values: values.map(DatabaseValue.text))
            do {
                try await PostgresTransactionAccess.requireWritable(on: session)
                XCTFail("Read-only access must block table changes")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.sqlState, "25006")
                XCTAssertTrue(error.message.contains(reason), error.message)
                XCTAssertTrue(error.message.contains("draft is preserved"))
            }
            let commands = await session.commands
            XCTAssertEqual(commands.count, 1)
            XCTAssertTrue(commands[0].hasPrefix("SELECT "))
        }
    }

    func testMissingOrMalformedServerResponseDoesNotAllowWrites() async throws {
        for values in [nil, [.text("off")], [.text("off"), .text("off"), .null], [.text("unknown"), .text("off"), .text("false")]] as [DatabaseRow?] {
            let session = TransactionAccessMockSession(values: values)
            do { try await PostgresTransactionAccess.requireWritable(on: session); XCTFail("Unverified server access") }
            catch { XCTAssertTrue(error.localizedDescription.contains("transaction access")) }
        }
    }
}

@MainActor
final class PostgresTransactionAccessIntegrationTests: XCTestCase {
    func testExplicitEditingOverridesDefaultButPreservesAnExistingReadOnlyTransaction() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["DB3_TEST_PORT"], let port = Int(value) else { throw XCTSkip("Disposable PostgreSQL fixture is not running.") }
        let profile = ConnectionProfile(host: environment["DB3_TEST_HOST"] ?? "127.0.0.1", port: port,
                                        database: environment["DB3_TEST_DATABASE"] ?? "postgres",
                                        username: environment["DB3_TEST_USER"] ?? NSUserName(), tls: .disable, environment: .production)
        let raw = PostgresSession()
        _ = try await raw.connect(profile: profile, password: environment["DB3_TEST_PASSWORD"] ?? "")
        let owner = ManagedSession(session: raw, environment: profile.environment)
        do {
            _ = try await raw.execute(sql: "SET SESSION default_transaction_read_only = on") { _ in }
            _ = try await owner.run(sql: "SELECT 1", mode: .manual) { _ in }
            do {
                try await owner.withExclusiveOperation { try await PostgresTransactionAccess.requireWritable(on: $0) }
                XCTFail("Ordinary queries must inherit the read-only session default")
            } catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "25006") }
            let readOnlyState = await owner.transactionState()
            XCTAssertEqual(readOnlyState, .inTransaction, "A read-only preflight must leave the transaction usable")
            _ = try await owner.rollback()

            _ = try await owner.run(sql: "SELECT 1", mode: .manual, requiresWritableTransaction: true) { _ in }
            try await owner.withExclusiveOperation { try await PostgresTransactionAccess.requireWritable(on: $0) }
            _ = try await owner.rollback()

            _ = try await owner.run(sql: "BEGIN READ ONLY", mode: .manual) { _ in }
            _ = try await owner.run(sql: "SELECT 1", mode: .manual, requiresWritableTransaction: true) { _ in }
            do {
                try await owner.withExclusiveOperation { try await PostgresTransactionAccess.requireWritable(on: $0) }
                XCTFail("Explicit editing must preserve an already-open read-only transaction")
            } catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "25006") }
            let existingState = await owner.transactionState()
            XCTAssertEqual(existingState, .inTransaction)
            _ = try await owner.rollback()
        } catch {
            await raw.disconnect()
            throw error
        }
        await raw.disconnect()
    }
}

private actor TransactionAccessMockSession: DatabaseSession {
    let values: DatabaseRow?
    private(set) var commands: [String] = []
    init(values: DatabaseRow?) { self.values = values }
    func connect(profile: ConnectionProfile, password: String) async throws -> SessionInfo { SessionInfo(serverVersion: "test", backendPID: 0) }
    func transactionState() async -> TransactionState { .inTransaction }
    func cancel() async {}
    func disconnect() async {}
    func execute(sql: String, onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        commands.append(sql)
        if let values { try await onEvent(.rows(RowBatch(rows: [values]))) }
        return QuerySummary(command: "SELECT 1", rowCount: values == nil ? 0 : 1, transaction: .inTransaction, elapsed: 0)
    }
}
