import XCTest
import DB3Core

final class ResultEditProjectionTests: XCTestCase {
    func testReorderedAliasesExpressionsAndDomainUseCanonicalAttributeIndices() throws {
        let mapping = try ResultEditProjection(table: table(), columns: projectedColumns())
        XCTAssertEqual(mapping.resultToTable, [1, 2, nil, 0, 1, 3])
        XCTAssertTrue(mapping.hasExpressions)
        XCTAssertFalse(mapping.hasHiddenVersion)
        XCTAssertEqual(try mapping.primaryKey(in: projectedRow, table: table()), [.text("42"), .text("tenant-a")])
    }

    func testReturningRefreshesEveryAliasButPreservesExpressionAndVisibleRowShape() throws {
        let mapping = try ResultEditProjection(table: table(), columns: projectedColumns())
        let fresh = EditableRowSnapshot(rowIndex: 123, values: [
            .text("tenant-a"), .text("new title"), .text("42"), .text("5"), .text("999.0000000000000001")
        ], version: "202")
        let result = try mapping.projectedRow(applying: fresh, to: projectedRow)
        XCTAssertEqual(result, [.text("new title"), .text("42"), .text("computed before update"), .text("tenant-a"), .text("new title"), .text("5")])
        XCTAssertEqual(result.count, projectedColumns().count)
        XCTAssertEqual(projectedRow[0], .text("old title"), "Projection must not mutate the fetched original.")
    }

    func testHiddenVersionIsPositionalAndDoesNotOverwriteVisibleColumnNamedXmin() throws {
        let metadata = table()
        var columns = metadata.databaseColumns
        columns[1].name = "xmin"
        let mapping = try ResultEditProjection(table: metadata, columns: columns, hasHiddenVersion: true)
        XCTAssertFalse(mapping.hasExpressions)
        let original: DatabaseRow = [.text("tenant-a"), .text("visible xmin value"), .text("42"), .text("4"), .null, .text("200")]
        let snapshot = EditableRowSnapshot(rowIndex: 0, values: [.text("tenant-a"), .text("updated visible text"), .text("42"), .text("4"), .null], version: "201")
        let refreshed = try mapping.projectedRow(applying: snapshot, to: original)
        XCTAssertEqual(refreshed[1], .text("updated visible text"))
        XCTAssertEqual(refreshed.last, .text("201"))
        XCTAssertEqual(refreshed.count, columns.count + 1)
        XCTAssertEqual(try mapping.primaryKey(in: refreshed, table: metadata), [.text("42"), .text("tenant-a")])
    }

    func testDuplicateProjectedBaseValuesMustAgreeIncludingNullAndEmptyText() throws {
        let mapping = try ResultEditProjection(table: table(), columns: projectedColumns())
        var row = projectedRow
        row[4] = .text("different alias value")
        XCTAssertThrowsError(try mapping.primaryKey(in: row, table: table()))
        row[0] = .null; row[4] = .text("")
        XCTAssertThrowsError(try mapping.primaryKey(in: row, table: table()))
        row[4] = .null
        XCTAssertEqual(try mapping.primaryKey(in: row, table: table()), [.text("42"), .text("tenant-a")])
    }

    func testMissingNullUnsupportedOrDisagreeingPrimaryKeysCannotIdentifyAnEdit() throws {
        XCTAssertThrowsError(try ResultEditProjection(table: table(), columns: [
            direct(0, "record_id", attribute: 5, oid: 23), direct(1, "title", attribute: 3, oid: 25)
        ]))
        let mapping = try ResultEditProjection(table: table(), columns: projectedColumns())
        var nullKey = projectedRow; nullKey[3] = .null
        XCTAssertThrowsError(try mapping.primaryKey(in: nullKey, table: table()))

        var duplicated = projectedColumns()
        duplicated.append(direct(6, "same_id", attribute: 5, oid: 23))
        let withDuplicate = try ResultEditProjection(table: table(), columns: duplicated)
        XCTAssertThrowsError(try withDuplicate.primaryKey(in: projectedRow + [.text("43")], table: table()))
        XCTAssertEqual(try withDuplicate.primaryKey(in: projectedRow + [.text("42")], table: table()), [.text("42"), .text("tenant-a")])

        let unsupportedKey = table(primary: [9])
        XCTAssertThrowsError(try ResultEditProjection(table: unsupportedKey, columns: [direct(0, "domain_key", attribute: 9, oid: 23)]))
    }

    func testSecondRelationMissingProvenanceAndSupportedTypeMismatchAreRejected() throws {
        var columns = projectedColumns()
        columns[2] = DatabaseColumn(index: 2, name: "joined", typeOID: 25, relationOID: 99, attributeNumber: 1)
        XCTAssertThrowsError(try ResultEditProjection(table: table(), columns: columns))
        columns = projectedColumns()
        columns[2] = DatabaseColumn(index: 2, name: "malformed", typeOID: 25, attributeNumber: 3)
        XCTAssertThrowsError(try ResultEditProjection(table: table(), columns: columns))
        columns = projectedColumns(); columns[0].typeOID = 1043
        XCTAssertThrowsError(try ResultEditProjection(table: table(), columns: columns))
        columns = projectedColumns(); columns[0].attributeNumber = 100
        XCTAssertThrowsError(try ResultEditProjection(table: table(), columns: columns))
    }

    func testSystemColumnsStayReadOnlyExpressionsAndCannotSubstituteForKeys() throws {
        var columns = projectedColumns()
        columns[2] = DatabaseColumn(index: 2, name: "xmin", typeOID: 28, relationOID: 42, attributeNumber: -2)
        let mapping = try ResultEditProjection(table: table(), columns: columns)
        XCTAssertNil(mapping.resultToTable[2])
        XCTAssertTrue(mapping.hasExpressions)
        XCTAssertThrowsError(try ResultEditProjection(table: table(), columns: [DatabaseColumn(index: 0, name: "ctid", typeOID: 27, relationOID: 42, attributeNumber: -1)]))
    }

    func testMalformedResultAndReplacementShapesWrongSourceAndKeyChangesAreRejected() throws {
        let metadata = table()
        let mapping = try ResultEditProjection(table: metadata, columns: projectedColumns())
        XCTAssertThrowsError(try mapping.primaryKey(in: Array(projectedRow.dropLast()), table: metadata))
        XCTAssertThrowsError(try mapping.primaryKey(in: projectedRow + [.text("surprise")], table: metadata))
        XCTAssertThrowsError(try mapping.primaryKey(in: projectedRow, table: table(revision: "new metadata")))
        let short = EditableRowSnapshot(rowIndex: 0, values: [.text("tenant-a")], version: "202")
        XCTAssertThrowsError(try mapping.projectedRow(applying: short, to: projectedRow))
        let invalidVersion = EditableRowSnapshot(rowIndex: 0, values: [.text("tenant-a"), .null, .text("42"), .null, .null], version: "bad")
        XCTAssertThrowsError(try mapping.projectedRow(applying: invalidVersion, to: projectedRow))
        let differentKey = EditableRowSnapshot(rowIndex: 0, values: [.text("tenant-a"), .null, .text("900"), .null, .null], version: "202")
        XCTAssertThrowsError(try mapping.projectedRow(applying: differentKey, to: projectedRow))
        var indices = projectedColumns(); indices[1].index = 9
        XCTAssertThrowsError(try ResultEditProjection(table: metadata, columns: indices))
    }

    private var projectedRow: DatabaseRow {
        [.text("old title"), .text("42"), .text("computed before update"), .text("tenant-a"), .text("old title"), .text("4")]
    }
    private func projectedColumns() -> [DatabaseColumn] {
        [direct(0, "title alias", attribute: 3, oid: 25), direct(1, "key", attribute: 5, oid: 23),
         DatabaseColumn(index: 2, name: "expression"), direct(3, "tenant", attribute: 1, oid: 25),
         direct(4, "duplicate title", attribute: 3, oid: 25), direct(5, "domain", attribute: 9, oid: 23)]
    }
    private func direct(_ index: Int, _ name: String, attribute: Int, oid: UInt32) -> DatabaseColumn {
        DatabaseColumn(index: index, name: name, typeOID: oid, relationOID: 42, attributeNumber: attribute)
    }
    private func table(primary: [Int] = [5, 1], revision: String = "r1") -> EditableTable {
        EditableTable(relationOID: 42, schema: "public", name: "records", columns: [
            EditableColumn(index: 0, attributeNumber: 1, name: "tenant", typeOID: 25, typeSQL: "pg_catalog.text", nullable: false, kind: .text, readOnlyReason: "Primary key"),
            EditableColumn(index: 1, attributeNumber: 3, name: "title", typeOID: 25, typeSQL: "pg_catalog.text", nullable: true, kind: .text),
            EditableColumn(index: 2, attributeNumber: 5, name: "id", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: false, kind: .integer, readOnlyReason: "Primary key"),
            EditableColumn(index: 3, attributeNumber: 9, name: "domain", typeOID: 9000, typeSQL: "", nullable: true, kind: nil, readOnlyReason: "Unsupported domain"),
            EditableColumn(index: 4, attributeNumber: 10, name: "amount", typeOID: 1700, typeSQL: "pg_catalog.numeric", nullable: true, kind: .decimal)
        ], primaryKeyAttributes: primary, metadataRevision: revision)
    }
}
