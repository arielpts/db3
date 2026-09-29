import Foundation

/// A deterministic slow source for UI development; never represents a real server.
public actor DemoSession: DatabaseSession {
    private var connected = false
    private var active: UUID?
    private var cancelled = false
    private let totalRows: Int
    public init(totalRows: Int = 10_000) { self.totalRows = totalRows }
    public func connect(profile: ConnectionProfile, password: String) async throws -> SessionInfo {
        connected = true
        return SessionInfo(serverVersion: "Sample data • no server", backendPID: 0)
    }
    public func execute(sql: String, onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary {
        guard connected else { throw DatabaseError("The sample session is disconnected.", connectionLost: true) }
        guard active == nil else { throw DatabaseError("A query is already running.") }
        let id = UUID(); active = id; cancelled = false
        defer { if active == id { active = nil } }
        let start = Date()
        try await onEvent(.columns([
            DatabaseColumn(index: 0, name: "id", typeOID: 23),
            DatabaseColumn(index: 1, name: "name"),
            DatabaseColumn(index: 2, name: "email"),
            DatabaseColumn(index: 3, name: "plan"),
            DatabaseColumn(index: 4, name: "revenue", typeOID: 1700),
            DatabaseColumn(index: 5, name: "created_at", typeOID: 1184),
        ]))
        for start in stride(from: 0, to: totalRows, by: 256) {
            try Task.checkCancellation()
            guard !cancelled, connected else { throw DatabaseError("Query cancelled.", sqlState: "57014") }
            let rows: [DatabaseRow] = (start..<min(start + 256, totalRows)).map { index in
                let names = ["Olivia Chen", "Lucas Martins", "Amelia Wilson", "Noah Garcia", "Sofia Costa", "Ethan Kim"]
                return [.text(String(index + 1)), .text(names[index % names.count]), .text("member\(index + 1)@example.com"), .text(index % 3 == 0 ? "Pro" : "Standard"), .text(index % 3 == 0 ? "29.00" : "9.00"), index % 17 == 0 ? .null : .text("2026-09-01 10:24:00+00")]
            }
            try await onEvent(.rows(RowBatch(rows: rows)))
            try await Task.sleep(for: .milliseconds(12))
        }
        return QuerySummary(command: "SAMPLE", rowCount: totalRows, transaction: .idle, elapsed: Date().timeIntervalSince(start))
    }
    public func cancel() { cancelled = true }
    public func disconnect() { connected = false; cancelled = true }
    public func transactionState() -> TransactionState { .idle }
}
