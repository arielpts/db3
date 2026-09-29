import Foundation
import XCTest
import DB3Core

@MainActor
final class InsertEditingTests: XCTestCase {
    private func table(generatedKey: Bool = false) -> EditableTable {
        EditableTable(relationOID: 42, schema: "odd\"schema", name: "items", columns: [
            EditableColumn(index: 0, attributeNumber: 1, name: "id", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: false, kind: .integer,
                readOnlyReason: "Primary key", insertReadOnlyReason: generatedKey ? "Identity columns use their database default." : nil, hasDefault: generatedKey),
            EditableColumn(index: 1, attributeNumber: 2, name: "display\"name", typeOID: 25, typeSQL: "pg_catalog.text", nullable: true, kind: .text, hasDefault: true),
            EditableColumn(index: 2, attributeNumber: 3, name: "calculated", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: false, kind: .integer,
                readOnlyReason: "Generated", insertReadOnlyReason: "Generated", hasDefault: true)
        ], primaryKeyAttributes: [1], metadataRevision: "r1")
    }
    private func context(_ table: EditableTable) -> EditSourceContext {
        EditSourceContext(sessionID: UUID(), resultRevision: UUID(), transactionEpoch: 0, relationOID: table.relationOID, metadataRevision: table.metadataRevision)
    }

    func testInsertUsesExactParametersAndManualPrimaryKeyWithoutUpdatingKey() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        try await store.addInsert(rowIndex: 4)
        let malicious = "'; DROP TABLE items; -- 🐘"
        try await store.stageInsert(rowIndex: 4, replacements: [0: .text("123"), 1: .text(malicious)])
        let plan = try await store.makePlan(mode: .manual, environment: .production)
        let statement = try XCTUnwrap(plan.statements.first)
        XCTAssertTrue(statement.isInsert)
        XCTAssertEqual(statement.rowIndex, 4)
        XCTAssertNil(statement.row)
        XCTAssertEqual(statement.insertedRow?.values, [0: .text("123"), 1: .text(malicious)])
        XCTAssertEqual(statement.parameters.map(\.value), [.text("123"), .text(malicious)])
        XCTAssertTrue(statement.sql.contains("INSERT INTO \"odd\"\"schema\".\"items\"\n(\"id\", \"display\"\"name\")\nVALUES ($1::pg_catalog.int4, $2::pg_catalog.text)"))
        XCTAssertFalse(statement.sql.contains(malicious))
        XCTAssertTrue(statement.sql.contains("RETURNING \"id\", \"display\"\"name\", \"calculated\", xmin::text"))
        XCTAssertThrowsError(try EditDraftStore.validate(.text("123"), column: table.columns[0]))
        await store.discard()
    }

    func testDefaultNullEmptyAreDistinctAndPreviewIsImmutable() async throws {
        let table = table(generatedKey: true), store = EditDraftStore(context: context(table), table: table)
        try await store.addInsert(rowIndex: 0)
        let defaults = try await store.makePlan(mode: .manual, environment: .unknown)
        XCTAssertTrue(defaults.statements[0].sql.contains("DEFAULT VALUES"))
        XCTAssertTrue(defaults.statements[0].parameters.isEmpty)
        try await store.stageInsert(rowIndex: 0, columnIndex: 1, value: .null)
        let null = try await store.makePlan(mode: .manual, environment: .unknown)
        XCTAssertEqual(null.statements[0].parameters.map(\.value), [.null])
        try await store.stageInsert(rowIndex: 0, columnIndex: 1, value: .text(""))
        let empty = try await store.makePlan(mode: .manual, environment: .unknown)
        XCTAssertEqual(empty.statements[0].parameters.map(\.value), [.text("")])
        try await store.useDefault(rowIndex: 0, columnIndex: 1)
        let state = await store.state()
        XCTAssertTrue(state.hasChanges)
        XCTAssertEqual(state.changedRowCount, 1)
        XCTAssertEqual(state.changedCellCount, 0)
        XCTAssertEqual(null.statements[0].insertedRow?.values[1], .null)
        let matches = await store.matches(empty)
        XCTAssertFalse(matches)
        await store.discard()
    }

    func testRequiredColumnsAndGeneratedValuesCannotBeSilentlyInserted() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        try await store.addInsert(rowIndex: 0)
        do { _ = try await store.makePlan(mode: .manual, environment: .unknown); XCTFail("Required primary key") }
        catch { XCTAssertTrue(error.localizedDescription.contains("id")) }
        do { try await store.stageInsert(rowIndex: 0, columnIndex: 0, value: .null); XCTFail("Not nullable") } catch { }
        do { try await store.stageInsert(rowIndex: 0, columnIndex: 2, value: .text("4")); XCTFail("Generated") } catch { }
        try await store.stageInsert(rowIndex: 0, columnIndex: 0, value: .text("4"))
        _ = try await store.makePlan(mode: .manual, environment: .unknown)
        for environment in [ConnectionEnvironment.production, .unknown] {
            do { _ = try await store.makePlan(mode: .auto, environment: environment); XCTFail("Auto forbidden") } catch { }
        }
        await store.discard()
    }

    func testInsertAndUpdateUndoRedoRemainOneOrderedHistory() async throws {
        let table = table(generatedKey: true), store = EditDraftStore(context: context(table), table: table)
        let original = EditableRowSnapshot(rowIndex: 0, values: [.text("1"), .text("Old"), .text("2")], version: "20")
        try await store.stage(row: original, columnIndex: 1, value: .text("Changed"))
        try await store.addInsert(rowIndex: 1)
        try await store.stageInsert(rowIndex: 1, columnIndex: 1, value: .text("New"))
        try await store.undo()
        var state = await store.state()
        XCTAssertEqual(state.insertRows.first?.values, [:])
        XCTAssertEqual(state.rows.count, 1)
        try await store.undo()
        state = await store.state()
        XCTAssertTrue(state.insertRows.isEmpty)
        XCTAssertEqual(state.rows.count, 1)
        try await store.redo()
        try await store.redo()
        let plan = try await store.makePlan(mode: .manual, environment: .unknown)
        XCTAssertEqual(plan.statements.map(\.isInsert), [false, true])
        try await store.discardInsert(rowIndex: 1)
        try await store.undo()
        state = await store.state()
        XCTAssertEqual(state.insertRows.first?.values[1], .text("New"))
        do { try await store.addInsert(rowIndex: 0); XCTFail("Cannot share draft ID") } catch { }
        await store.discard()
    }

    func testInsertBudgetFailureDoesNotMutateAndMismatchedContextCannotStage() async throws {
        let table = table(generatedKey: true), store = EditDraftStore(context: context(table), table: table)
        try await store.addInsert(rowIndex: 0)
        let reserved = try EditPayloadReservation(bytes: 7 * 1024 * 1024)
        do { try await store.stageInsert(rowIndex: 0, columnIndex: 1, value: .text(String(repeating: "x", count: 600_000))); XCTFail("Budget must reject") } catch { }
        let state = await store.state()
        XCTAssertEqual(state.insertRows.first?.values, [:])
        try reserved.resize(bytes: 0)
        let stale = EditSourceContext(sessionID: UUID(), resultRevision: UUID(), transactionEpoch: 0, relationOID: table.relationOID, metadataRevision: "old")
        let staleStore = EditDraftStore(context: stale, table: table)
        do { try await staleStore.addInsert(rowIndex: 0); XCTFail("Metadata mismatch") } catch { }
        await store.discard()
    }
}
