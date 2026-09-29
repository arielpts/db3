import Foundation

public enum TLSMode: String, Codable, CaseIterable, Sendable {
    case verifyFull = "verify-full"
    case require
    case disable
    public var title: String {
        switch self { case .verifyFull: "Verify certificate & hostname"; case .require: "Encryption only"; case .disable: "Disabled (local development)" }
    }
}

public struct ConnectionProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var tls: TLSMode
    public var rootCertificate: String
    /// Initial Objects browser filter, using the exact schema name rather than a SQL-quoted identifier.
    /// This does not change a SQL session's search_path.
    public var defaultSchema: String = "public"
    public init(id: UUID = UUID(), name: String = "Local PostgreSQL", host: String = "localhost", port: Int = 5432, database: String = "postgres", username: String = NSUserName(), tls: TLSMode = .verifyFull, rootCertificate: String = "", defaultSchema: String = "public") {
        self.id = id; self.name = name; self.host = host; self.port = port; self.database = database; self.username = username; self.tls = tls; self.rootCertificate = rootCertificate
        self.defaultSchema = defaultSchema
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, tls, rootCertificate, defaultSchema
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        database = try values.decode(String.self, forKey: .database)
        username = try values.decode(String.self, forKey: .username)
        tls = try values.decode(TLSMode.self, forKey: .tls)
        rootCertificate = try values.decode(String.self, forKey: .rootCertificate)
        if values.contains(.defaultSchema) {
            defaultSchema = try values.decode(String.self, forKey: .defaultSchema)
        } else {
            defaultSchema = "public"
        }
    }
}

public struct DatabaseColumn: Codable, Hashable, Identifiable, Sendable {
    public var index: Int
    public var name: String
    public var typeOID: UInt32
    public var id: Int { index }
    public init(index: Int, name: String, typeOID: UInt32 = 25) { self.index = index; self.name = name; self.typeOID = typeOID }
}

public enum DatabaseValue: Codable, Hashable, Sendable {
    case null
    case text(String)
    public var displayText: String { switch self { case .null: "NULL"; case .text(let value): value } }
    public var byteCount: Int { switch self { case .null: 1; case .text(let value): value.utf8.count + 8 } }
}
public typealias DatabaseRow = [DatabaseValue]

public struct RowBatch: Codable, Sendable {
    public let rows: [DatabaseRow]
    public var byteCount: Int { rows.reduce(0) { $0 + $1.reduce(16) { $0 + $1.byteCount } } }
    public init(rows: [DatabaseRow]) { self.rows = rows }
}

public enum TransactionState: String, Sendable, Codable {
    case idle, inTransaction, failed, unknown
    public var title: String { switch self { case .idle: "Auto commit"; case .inTransaction: "In transaction"; case .failed: "Rollback required"; case .unknown: "Unknown" } }
}

public struct SessionInfo: Sendable {
    public var serverVersion: String
    public var backendPID: Int
    public init(serverVersion: String, backendPID: Int) { self.serverVersion = serverVersion; self.backendPID = backendPID }
}

public struct QuerySummary: Sendable {
    public var command: String
    public var rowCount: Int
    public var transaction: TransactionState
    public var elapsed: TimeInterval
    public init(command: String, rowCount: Int, transaction: TransactionState, elapsed: TimeInterval) { self.command = command; self.rowCount = rowCount; self.transaction = transaction; self.elapsed = elapsed }
}

public enum QueryEvent: Sendable {
    case columns([DatabaseColumn])
    case rows(RowBatch)
    case notice(String)
}

public struct DatabaseError: Error, LocalizedError, Sendable {
    public var message: String
    public var sqlState: String?
    public var connectionLost: Bool
    public init(_ message: String, sqlState: String? = nil, connectionLost: Bool = false) { self.message = message; self.sqlState = sqlState; self.connectionLost = connectionLost }
    public var errorDescription: String? { message }
}

/// The awaited consumer is the backpressure boundary: never queue unbounded row tasks.
public protocol DatabaseSession: Sendable {
    func connect(profile: ConnectionProfile, password: String) async throws -> SessionInfo
    func execute(sql: String, onEvent: @escaping @Sendable (QueryEvent) async throws -> Void) async throws -> QuerySummary
    func cancel() async
    func disconnect() async
    func transactionState() async -> TransactionState
}
