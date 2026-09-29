import Foundation
import DB3Core

/// The application shares one instance. A completion chain admits at most one
/// catalog owner, including asynchronous connect, cancellation recovery, and
/// disconnect. Actor isolation alone would not protect these suspension points.
public actor PostgresCatalogService: CatalogService {
    private var tail: Task<Void, Never>?
    private var requests: [UUID: Task<CatalogPage, any Error>] = [:]
    private var epoch: UInt64 = 0
    private var session: PostgresSession?
    private var source: CatalogSource?
    private var database: CatalogDatabaseIdentity?
    private var generation = UUID()

    public init() {}

    public func page(source: CatalogSource, password: String, query: CatalogQuery) async throws -> CatalogPage {
        let predecessor = tail, requestedEpoch = epoch, requestID = UUID()
        let operation = Task {
            await predecessor?.value
            try Task.checkCancellation()
            return try await self.performPage(source: source, password: password, query: query, epoch: requestedEpoch)
        }
        requests[requestID] = operation
        tail = Task { _ = await operation.result }
        defer { requests[requestID] = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.value
        } onCancel: { operation.cancel() }
    }

    public func disconnect() async {
        epoch &+= 1
        for operation in requests.values { operation.cancel() }
        let predecessor = tail
        let closing = Task {
            await predecessor?.value
            await self.closeSession()
        }
        tail = closing
        await closing.value
    }

    private func performPage(source requestedSource: CatalogSource, password: String,
                             query: CatalogQuery, epoch requestedEpoch: UInt64) async throws -> CatalogPage {
        try ensureCurrent(requestedEpoch)
        guard (1...500).contains(query.limit) else {
            throw DatabaseError("Catalog page size must be between 1 and 500 objects.")
        }
        if source != requestedSource || session == nil {
            await closeSession()
            try ensureCurrent(requestedEpoch)
            let connection = PostgresSession()
            session = connection
            do {
                _ = try await connection.connect(profile: requestedSource.profile, password: password)
                try ensureCurrent(requestedEpoch)
                // Server and client deadlines complement each other: the client
                // also bounds a stalled network while the server bounds work.
                _ = try await Self.rows(on: connection, sql: "SELECT pg_catalog.set_config('statement_timeout', '10000', false)", parameters: [], maximumRows: 1)
                let identity = try await Self.rows(on: connection, sql: """
                    SELECT oid::text, datname::text
                    FROM pg_catalog.pg_database
                    WHERE datname = pg_catalog.current_database()
                    """, parameters: [], maximumRows: 1)
                guard identity.count == 1, identity[0].count == 2,
                      let oid = UInt32(try Self.text(identity[0][0])),
                      try Self.text(identity[0][1]) == requestedSource.profile.database else {
                    throw DatabaseError("The connected database does not match this connection's saved database.")
                }
                try ensureCurrent(requestedEpoch)
                database = CatalogDatabaseIdentity(oid: oid, name: requestedSource.profile.database)
                source = requestedSource
                generation = UUID()
            } catch {
                await closeSession()
                throw error
            }
        }
        guard let session, let database else { throw DatabaseError("The catalog connection is not available.", connectionLost: true) }
        do {
            let schemaLimit = 5000
            let schemaRows: [DatabaseRow]
            if query.cursor == nil {
                schemaRows = try await Self.rows(on: session, sql: Self.schemasSQL,
                                                 parameters: [String(schemaLimit + 1)], maximumRows: schemaLimit + 1)
                try ensureCurrent(requestedEpoch)
            } else { schemaRows = [] }
            let schemas = try schemaRows.prefix(schemaLimit).map { row in
                guard row.count == 1 else { throw DatabaseError("PostgreSQL returned invalid schema metadata.") }
                return try Self.text(row[0])
            }
            let rows = try await Self.rows(on: session, sql: Self.catalogSQL, parameters: [
                query.search, query.kind?.rawValue, query.cursor?.schema, query.cursor?.name,
                query.cursor.map { String($0.relationOID) }, String(query.limit + 1), query.schema
            ], maximumRows: query.limit + 1)
            try ensureCurrent(requestedEpoch)
            let objects = try rows.prefix(query.limit).map {
                try Self.decode($0, source: requestedSource, database: database, generation: generation)
            }
            let nextCursor: CatalogCursor?
            if rows.count > query.limit, let last = objects.last {
                nextCursor = CatalogCursor(schema: last.schema, name: last.name, relationOID: last.id.relationOID)
            } else { nextCursor = nil }
            return CatalogPage(objects: objects, nextCursor: nextCursor, database: database, generation: generation,
                               schemas: schemas, schemasTruncated: schemaRows.count > schemaLimit)
        } catch {
            // execute returns only after cancellation recovery. Recovered
            // cancellation and SQL errors can reuse this independent session;
            // protocol loss closes it before another connection is admitted.
            if (error as? DatabaseError)?.connectionLost == true { await closeSession() }
            throw error
        }
    }

    private func ensureCurrent(_ requestedEpoch: UInt64) throws {
        try Task.checkCancellation()
        guard requestedEpoch == epoch else { throw CancellationError() }
    }

    private func closeSession() async {
        if let session { await session.disconnect() }
        session = nil; source = nil; database = nil
    }

    private static func rows(on session: PostgresSession, sql: String, parameters: [String?],
                             maximumRows: Int) async throws -> [DatabaseRow] {
        try await withThrowingTaskGroup(of: [DatabaseRow].self) { group in
            group.addTask {
                let collector = CatalogRowCollector(maximumRows: maximumRows)
                _ = try await session.execute(sql: sql, parameters: parameters) { event in
                    try await collector.consume(event)
                }
                try Task.checkCancellation()
                return await collector.rows
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw DatabaseError("Loading objects timed out after 10 seconds. Retry to load the catalog again.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
            // A task group does not leave until both children settle, so a
            // deadline cannot release the admission gate before recovery ends.
        }
    }

    private static func text(_ value: DatabaseValue) throws -> String {
        guard case .text(let value) = value else { throw DatabaseError("PostgreSQL returned incomplete object metadata.") }
        return value
    }

    private static func decode(_ row: DatabaseRow, source: CatalogSource, database: CatalogDatabaseIdentity,
                               generation: UUID) throws -> DatabaseObject {
        guard row.count == 11,
              let relationOID = UInt32(try text(row[0])), let schemaOID = UInt32(try text(row[1])) else {
            throw DatabaseError("PostgreSQL returned invalid object metadata.")
        }
        let relationKind = try text(row[4])
        let kind: DatabaseObjectKind
        switch relationKind {
        case "r", "p": kind = .table
        case "v": kind = .view
        case "m": kind = .materializedView
        default: throw DatabaseError("PostgreSQL returned an unsupported object kind.")
        }
        return try DatabaseObject(
            id: DatabaseObjectID(source: source, databaseOID: database.oid, relationOID: relationOID, generation: generation),
            schemaOID: schemaOID, schema: text(row[2]), name: text(row[3]), kind: kind,
            isPartition: text(row[5]) == "true", isPartitioned: relationKind == "p",
            persistence: text(row[6]), isPopulated: kind == .materializedView ? text(row[7]) == "true" : nil,
            hasSchemaUsage: text(row[8]) == "true", hasTableSelect: text(row[9]) == "true", hasAnyColumnSelect: text(row[10]) == "true"
        )
    }

    private static let schemasSQL = """
        SELECT n.nspname::text
        FROM pg_catalog.pg_namespace AS n
        WHERE n.nspname <> 'information_schema'
          AND pg_catalog.left(n.nspname::text, 3) <> 'pg_'
        ORDER BY n.nspname::text COLLATE "C"
        LIMIT $1::integer
        """

    private static let catalogSQL = """
        SELECT c.oid::text, n.oid::text, n.nspname::text, c.relname::text,
               c.relkind::text, c.relispartition::text, c.relpersistence::text, c.relispopulated::text,
               pg_catalog.has_schema_privilege(n.oid, 'USAGE')::text,
               pg_catalog.has_table_privilege(c.oid, 'SELECT')::text,
               pg_catalog.has_any_column_privilege(c.oid, 'SELECT')::text
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p', 'v', 'm')
          AND c.relpersistence <> 't'
          AND n.nspname <> 'information_schema'
          AND pg_catalog.left(n.nspname::text, 3) <> 'pg_'
          AND ($7::text IS NULL OR n.nspname::text COLLATE "C" = $7::text COLLATE "C")
          AND ($1::text = ''
               OR pg_catalog.strpos(pg_catalog.lower(n.nspname::text), pg_catalog.lower($1::text)) > 0
               OR pg_catalog.strpos(pg_catalog.lower(c.relname::text), pg_catalog.lower($1::text)) > 0
               OR pg_catalog.strpos(pg_catalog.lower(n.nspname::text || '.' || c.relname::text), pg_catalog.lower($1::text)) > 0)
          AND ($2::text IS NULL
               OR ($2::text = 'table' AND c.relkind IN ('r', 'p'))
               OR ($2::text = 'view' AND c.relkind = 'v')
               OR ($2::text = 'materializedView' AND c.relkind = 'm'))
          AND ($3::text IS NULL OR
               (n.nspname::text COLLATE "C", c.relname::text COLLATE "C", c.oid) >
               ($3::text COLLATE "C", $4::text COLLATE "C", $5::oid))
        ORDER BY n.nspname::text COLLATE "C", c.relname::text COLLATE "C", c.oid
        LIMIT $6::integer
        """
}

private actor CatalogRowCollector {
    let maximumRows: Int
    private(set) var rows: [DatabaseRow] = []
    private var bytes = 0
    init(maximumRows: Int) { self.maximumRows = maximumRows }
    func consume(_ event: QueryEvent) throws {
        guard case .rows(let batch) = event else { return }
        guard rows.count + batch.rows.count <= maximumRows, bytes + batch.byteCount <= 8 * 1024 * 1024 else {
            throw DatabaseError("The object metadata response exceeded its memory limit. Narrow your search and retry.")
        }
        rows.append(contentsOf: batch.rows); bytes += batch.byteCount
    }
}
