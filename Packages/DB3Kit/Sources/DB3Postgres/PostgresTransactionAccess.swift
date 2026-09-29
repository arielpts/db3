import Foundation
import DB3Core

/// Checks the server's effective transaction access without changing it. The
/// caller owns the worksheet lease and protects this read with its savepoint.
public enum PostgresTransactionAccess {
    public static func requireWritable(on session: any DatabaseSession) async throws {
        let values = try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                let collector = TransactionAccessCollector()
                _ = try await session.execute(sql: """
                    SELECT pg_catalog.current_setting('transaction_read_only'),
                           pg_catalog.current_setting('default_transaction_read_only'),
                           pg_catalog.pg_is_in_recovery()::text
                    """) { event in try await collector.consume(event) }
                return try await collector.values()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw DatabaseError("Checking transaction access timed out. Your draft is preserved; retry after checking the connection.")
            }
            defer { group.cancelAll() }
            guard let values = try await group.next() else { throw CancellationError() }
            return values
        }
        try Task.checkCancellation()
        guard values[0] == "on" || values[2] == "true" else { return }
        let message: String
        if values[2] == "true" {
            message = "This connection is a read-only PostgreSQL replica. Your draft is preserved. Copy any values you want to keep, discard the grid draft, and connect to the writable primary before editing again."
        } else if values[1] == "on" {
            message = "This transaction is read-only, and this connection defaults to read-only transactions. Your draft is preserved. Copy any values you want to keep, discard the grid draft, then roll back and reload Edit Table Data to start a new writable transaction."
        } else {
            message = "This transaction is read-only. Your draft is preserved. Copy any values you want to keep, discard the grid draft, then roll back and reload Edit Table Data to start a new writable transaction."
        }
        throw DatabaseError(message, sqlState: "25006")
    }
}

private actor TransactionAccessCollector {
    private var row: DatabaseRow?

    func consume(_ event: QueryEvent) throws {
        guard case .rows(let batch) = event else { return }
        for value in batch.rows {
            guard row == nil, value.count == 3, value.allSatisfy({ $0.byteCount <= 16 }) else {
                throw DatabaseError("PostgreSQL returned invalid transaction access information. No table changes were sent.")
            }
            row = value
        }
    }

    func values() throws -> [String] {
        guard let row, case .text(let current) = row[0], case .text(let defaults) = row[1], case .text(let recovery) = row[2],
              ["on", "off"].contains(current), ["on", "off"].contains(defaults), ["true", "false"].contains(recovery) else {
            throw DatabaseError("PostgreSQL did not confirm transaction access. No table changes were sent.")
        }
        return [current, defaults, recovery]
    }
}
