import Foundation

/// Maps a displayed query result onto one canonical editable table. Aliases and
/// result positions never become SQL identifiers, and expression values remain
/// part of the fetched query result rather than pretending to be base columns.
public struct ResultEditProjection: Sendable, Equatable {
    public let resultToTable: [Int?]
    public let hasHiddenVersion: Bool
    public var hasExpressions: Bool { resultToTable.contains(nil) }

    private let canonicalColumnCount: Int
    private let relationOID: UInt32
    private let metadataRevision: String
    private let canonicalAttributes: [Int]
    private let primaryKeyAttributes: [Int]
    private let primaryKeyIndices: [Int]
    private let resultPositions: [[Int]]

    /// `columns` contains only visible grid columns. An app-owned table result
    /// can additionally store one trailing xmin value, indicated by the flag.
    public init(table: EditableTable, columns: [DatabaseColumn], hasHiddenVersion: Bool = false) throws {
        if let reason = table.readOnlyReason { throw DatabaseError(reason) }
        guard table.relationOID != 0, !table.columns.isEmpty,
              table.columns.enumerated().allSatisfy({ $0.offset == $0.element.index }),
              table.columns.allSatisfy({ $0.attributeNumber > 0 }),
              Set(table.columns.map(\.attributeNumber)).count == table.columns.count else {
            throw DatabaseError("The editable table has incomplete or ambiguous column metadata.")
        }
        guard columns.enumerated().allSatisfy({ $0.offset == $0.element.index }) else {
            throw DatabaseError("The query result column positions are incomplete or out of order.")
        }
        let attributes = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.attributeNumber, $0.index) })
        guard !table.primaryKeyAttributes.isEmpty,
              Set(table.primaryKeyAttributes).count == table.primaryKeyAttributes.count,
              table.primaryKeyAttributes.allSatisfy({ attributes[$0] != nil }) else {
            throw DatabaseError("A complete primary key is required for editing query results.")
        }
        var mapping: [Int?] = []
        var positions = Array(repeating: [Int](), count: table.columns.count)
        for (resultIndex, column) in columns.enumerated() {
            let source = column.relationOID ?? 0
            let attribute = column.attributeNumber ?? 0
            guard source == 0 || source == table.relationOID else {
                throw DatabaseError("This query contains columns from more than one base table. Its editing target is ambiguous.")
            }
            if source == 0 {
                guard attribute <= 0 else { throw DatabaseError("A result column has incomplete source metadata.") }
                mapping.append(nil)
                continue
            }
            // System columns and whole-row/expression outputs are not ordinary
            // writable attributes, even when PostgreSQL identifies their table.
            if attribute <= 0 { mapping.append(nil); continue }
            guard let tableIndex = attributes[attribute] else {
                throw DatabaseError("A query result column no longer exists in the table metadata. Run the query again.")
            }
            let canonical = table.columns[tableIndex]
            // PostgreSQL reports a domain's base type in wire metadata. Such a
            // column remains mapped for display but its unsupported type is read-only.
            guard canonical.kind == nil || column.typeOID == canonical.typeOID else {
                throw DatabaseError("A query result column's type no longer matches its base-table column.")
            }
            mapping.append(tableIndex)
            positions[tableIndex].append(resultIndex)
        }
        let keys = table.primaryKeyAttributes.compactMap { attributes[$0] }
        guard keys.allSatisfy({ !positions[$0].isEmpty && table.columns[$0].kind != nil }) else {
            throw DatabaseError("Include every supported primary-key column directly in the SELECT result to edit its rows.")
        }
        self.resultToTable = mapping
        self.hasHiddenVersion = hasHiddenVersion
        self.canonicalColumnCount = table.columns.count
        self.relationOID = table.relationOID
        self.metadataRevision = table.metadataRevision
        self.canonicalAttributes = table.columns.map(\.attributeNumber)
        self.primaryKeyAttributes = table.primaryKeyAttributes
        self.primaryKeyIndices = keys
        self.resultPositions = positions
    }

    /// Returns exact keys in primary-key constraint order. Duplicate projections
    /// of any base attribute must agree; a NULL key never identifies an edit row.
    public func primaryKey(in row: DatabaseRow, table: EditableTable) throws -> [DatabaseValue] {
        guard table.relationOID == relationOID, table.metadataRevision == metadataRevision,
              table.columns.count == canonicalColumnCount, table.columns.map(\.attributeNumber) == canonicalAttributes,
              table.primaryKeyAttributes == primaryKeyAttributes else {
            throw DatabaseError("This result projection belongs to different table metadata. Run the query again.")
        }
        try validate(row)
        return try projectedKey(in: row)
    }

    /// Applies canonical RETURNING/rebase values to every duplicate displayed
    /// alias while retaining the original result order, labels, and expressions.
    /// Expressions may now be stale; their presentation must request a rerun.
    public func projectedRow(applying snapshot: EditableRowSnapshot, to original: DatabaseRow) throws -> DatabaseRow {
        try validate(original)
        guard snapshot.values.count == canonicalColumnCount, UInt32(snapshot.version) != nil else {
            throw DatabaseError("The refreshed editable row is incomplete or has no valid version token.")
        }
        let originalKey = try projectedKey(in: original)
        let replacementKey = primaryKeyIndices.map { snapshot.values[$0] }
        guard originalKey == replacementKey else {
            throw DatabaseError("The refreshed row's primary key does not match this query result row.")
        }
        var result = original
        for (resultIndex, tableIndex) in resultToTable.enumerated() {
            if let tableIndex { result[resultIndex] = snapshot.values[tableIndex] }
        }
        if hasHiddenVersion { result[resultToTable.count] = .text(snapshot.version) }
        return result
    }

    private func validate(_ row: DatabaseRow) throws {
        guard row.count == resultToTable.count + (hasHiddenVersion ? 1 : 0) else {
            throw DatabaseError("The stored row no longer matches its query result projection.")
        }
        if hasHiddenVersion {
            guard case .text(let version) = row.last, UInt32(version) != nil else {
                throw DatabaseError("The stored editable row has no valid version token.")
            }
        }
        for aliases in resultPositions where aliases.count > 1 {
            let first = row[aliases[0]]
            guard aliases.dropFirst().allSatisfy({ row[$0] == first }) else {
                throw DatabaseError("Duplicate projections of a base-table column disagree. Run the query again before editing.")
            }
        }
    }

    private func projectedKey(in row: DatabaseRow) throws -> [DatabaseValue] {
        try primaryKeyIndices.map { index in
            let value = row[resultPositions[index][0]]
            guard value != .null else { throw DatabaseError("This result row has a NULL primary-key component and cannot be edited.") }
            return value
        }
    }
}
