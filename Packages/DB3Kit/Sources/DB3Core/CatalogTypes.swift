import Foundation

/// A revision changes whenever endpoint, credentials, or transport settings do.
/// No credential is retained in catalog identities or pages.
public struct CatalogSource: Hashable, Sendable {
    public let profile: ConnectionProfile
    public let revision: UUID
    public init(profile: ConnectionProfile, revision: UUID) {
        self.profile = profile; self.revision = revision
    }
}

public struct CatalogDatabaseIdentity: Hashable, Sendable {
    public let oid: UInt32
    public let name: String
    public init(oid: UInt32, name: String) { self.oid = oid; self.name = name }
}

public enum DatabaseObjectKind: String, CaseIterable, Hashable, Sendable {
    case table, view, materializedView
    public var title: String {
        switch self { case .table: "Table"; case .view: "View"; case .materializedView: "Materialized View" }
    }
    public var pluralTitle: String {
        switch self { case .table: "Tables"; case .view: "Views"; case .materializedView: "Materialized Views" }
    }
}

public struct DatabaseObjectID: Hashable, Sendable {
    public let source: CatalogSource
    public let databaseOID: UInt32
    public let relationOID: UInt32
    public let generation: UUID
    public init(source: CatalogSource, databaseOID: UInt32, relationOID: UInt32, generation: UUID) {
        self.source = source; self.databaseOID = databaseOID
        self.relationOID = relationOID; self.generation = generation
    }
}

public struct DatabaseObject: Identifiable, Hashable, Sendable {
    public let id: DatabaseObjectID
    public let schemaOID: UInt32
    public let schema: String
    public let name: String
    public let kind: DatabaseObjectKind
    public let isPartition: Bool
    public let isPartitioned: Bool
    public let persistence: String
    public let isPopulated: Bool?
    public let identityToken: String
    public let hasSchemaUsage: Bool
    public let hasTableSelect: Bool
    public let hasAnyColumnSelect: Bool

    public init(id: DatabaseObjectID, schemaOID: UInt32, schema: String, name: String,
                kind: DatabaseObjectKind, isPartition: Bool = false, isPartitioned: Bool = false,
                persistence: String = "p", isPopulated: Bool? = nil,
                identityToken: String = "", hasSchemaUsage: Bool = true, hasTableSelect: Bool = true, hasAnyColumnSelect: Bool = true) {
        self.id = id; self.schemaOID = schemaOID; self.schema = schema; self.name = name; self.kind = kind
        self.isPartition = isPartition; self.isPartitioned = isPartitioned; self.persistence = persistence
        self.identityToken = identityToken
        self.isPopulated = isPopulated; self.hasSchemaUsage = hasSchemaUsage
        self.hasTableSelect = hasTableSelect; self.hasAnyColumnSelect = hasAnyColumnSelect
    }

    public var qualifiedName: String { schema + "." + name }
    public var quotedQualifiedName: String { Self.quoteIdentifier(schema) + "." + Self.quoteIdentifier(name) }
    public var selectSQL: String { "SELECT *\nFROM \(quotedQualifiedName)\nLIMIT 1000;" }
    /// Conservative accounting for decoded values, value headers, and source identity.
    public var byteCount: Int {
        512 + schema.utf8.count + name.utf8.count + persistence.utf8.count
        + id.source.profile.name.utf8.count + id.source.profile.host.utf8.count
        + id.source.profile.database.utf8.count + id.source.profile.username.utf8.count
        + id.source.profile.rootCertificate.utf8.count + id.source.profile.defaultSchema.utf8.count
    }
    public static func quoteIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public struct CatalogCursor: Hashable, Sendable {
    public let schema: String
    public let name: String
    public let relationOID: UInt32
    public init(schema: String, name: String, relationOID: UInt32) {
        self.schema = schema; self.name = name; self.relationOID = relationOID
    }
}

/// Exact namespace membership is applied by PostgreSQL before pagination.
/// Optional identity evidence protects user overrides from drop/recreate reuse.
public struct CatalogMembership: Hashable, Codable, Sendable {
    public let schema: String, relation: String
    public let oid: UInt32?
    public let token: String?
    public init(schema: String, relation: String, oid: UInt32? = nil, token: String? = nil) {
        self.schema = schema; self.relation = relation; self.oid = oid; self.token = token
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schema.utf8.elementsEqual(rhs.schema.utf8) && lhs.relation.utf8.elementsEqual(rhs.relation.utf8)
            && lhs.oid == rhs.oid && lhs.token == rhs.token
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(Data(schema.utf8)); hasher.combine(Data(relation.utf8)); hasher.combine(oid); hasher.combine(token)
    }
}
public struct CatalogNamespaceFilter: Hashable, Sendable {
    public var included: [CatalogMembership]?
    public var excluded: [CatalogMembership]
    public init(included: [CatalogMembership]? = nil, excluded: [CatalogMembership] = []) {
        self.included = included; self.excluded = excluded
    }
}

public struct CatalogQuery: Hashable, Sendable {
    public let search: String
    public let kind: DatabaseObjectKind?
    /// An exact PostgreSQL schema name; nil includes all non-system schemas.
    public let schema: String?
    public let cursor: CatalogCursor?
    public let limit: Int
    public let namespaceFilter: CatalogNamespaceFilter
    public init(search: String = "", kind: DatabaseObjectKind? = nil, schema: String? = nil,
                cursor: CatalogCursor? = nil, limit: Int = 500, namespaceFilter: CatalogNamespaceFilter = .init()) {
        self.search = search; self.kind = kind; self.schema = schema; self.cursor = cursor; self.limit = limit
        self.namespaceFilter = namespaceFilter
    }
}

public struct CatalogPage: Sendable {
    public let objects: [DatabaseObject]
    public let nextCursor: CatalogCursor?
    public let database: CatalogDatabaseIdentity
    public let generation: UUID
    /// First-page discovery is independent of object filters and includes empty schemas.
    /// Appended pages omit discovery, so their empty array does not clear the first page's list.
    public let schemas: [String]
    public let schemasTruncated: Bool
    public init(objects: [DatabaseObject], nextCursor: CatalogCursor?, database: CatalogDatabaseIdentity, generation: UUID,
                schemas: [String] = [], schemasTruncated: Bool = false) {
        self.objects = objects; self.nextCursor = nextCursor; self.database = database; self.generation = generation
        self.schemas = schemas; self.schemasTruncated = schemasTruncated
    }
}

/// One catalog owner is shared by the application's browser. Task cancellation
/// targets that page operation and settles after protocol recovery. Disconnect
/// invalidates queued requests and waits for the physical session to close.
public protocol CatalogService: Sendable {
    func page(source: CatalogSource, password: String, query: CatalogQuery) async throws -> CatalogPage
    func disconnect() async
}
