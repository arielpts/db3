import Foundation
import XCTest
import DB3Core
import DB3Postgres

@MainActor
final class EditingTests: XCTestCase {
    private func table(metadata: FieldEditorMetadata? = nil) -> EditableTable {
        EditableTable(relationOID: 42, schema: "odd\"schema", name: "records", columns: [
            EditableColumn(index: 0, attributeNumber: 1, name: "id", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: false, kind: .integer, readOnlyReason: "Primary key"),
            EditableColumn(index: 1, attributeNumber: 2, name: "display\"name", typeOID: 25, typeSQL: "pg_catalog.text", nullable: true, kind: .text, applicationMetadata: metadata),
            EditableColumn(index: 2, attributeNumber: 3, name: "amount", typeOID: 1700, typeSQL: "pg_catalog.numeric", nullable: false, kind: .decimal)
        ], primaryKeyAttributes: [1], metadataRevision: "r1")
    }
    private func context(_ table: EditableTable) -> EditSourceContext {
        EditSourceContext(sessionID: UUID(), resultRevision: UUID(), transactionEpoch: 0, relationOID: table.relationOID, metadataRevision: table.metadataRevision)
    }
    private var row: EditableRowSnapshot { EditableRowSnapshot(rowIndex: 0, values: [.text("1"), .null, .text("0")], version: "20") }

    func testExactParametersNullAndImmutablePreview() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        let injection = "'; DROP TABLE records; -- 🐘"
        try await store.stage(row: row, columnIndex: 1, value: .text(injection))
        let plan = try await store.makePlan(mode: .manual, environment: .production)
        XCTAssertEqual(plan.statements.count, 1)
        let statement = plan.statements[0]
        XCTAssertTrue(statement.sql.contains("UPDATE ONLY \"odd\"\"schema\".\"records\""))
        XCTAssertTrue(statement.sql.contains("\"display\"\"name\" = $1::pg_catalog.text"))
        XCTAssertFalse(statement.sql.contains(injection))
        XCTAssertEqual(statement.parameters.map(\.value), [.text(injection), .text("1"), .text("20"), .null])
        XCTAssertEqual(statement.parameters.last?.text, nil)
        await assertTrue(store.matches(plan))
        try await store.stage(row: row, columnIndex: 1, value: .text("NULL"))
        await assertFalse(store.matches(plan))
        XCTAssertEqual(statement.parameters.first?.value, .text(injection))
        await store.discard()
    }

    func testNullEmptyUntouchedAndUndoCoalescing() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        try await store.stage(row: row, columnIndex: 1, value: .text(""))
        await assertEqual(store.state().changedCellCount, 1)
        try await store.stage(row: row, columnIndex: 1, value: .null)
        await assertTrue(store.state().rows.isEmpty)
        try await store.undo()
        await assertEqual(store.state().rows.first?.replacements[1], .text(""))
        try await store.redo()
        await assertTrue(store.state().rows.isEmpty)
        await store.discard()
    }

    func testTupleStagesOnceAndRebaseCannotUndoStaleVersion() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        try await store.stage(row: row, replacements: [1: .text("New"), 2: .text("999999999999999999999999999999.123456789")])
        await assertEqual(store.state().changedCellCount, 2)
        try await store.undo(); await assertTrue(store.state().rows.isEmpty)
        try await store.redo()
        let refreshed = EditableRowSnapshot(rowIndex: 0, values: [.text("1"), .text("Other writer"), .text("20")], version: "21")
        try await store.rebase(rowIndex: 0, onto: refreshed)
        let state = await store.state()
        XCTAssertFalse(state.canUndo)
        XCTAssertEqual(state.rows.first?.original, refreshed)
        XCTAssertEqual(state.rows.first?.replacements[1], .text("New"))
        await store.discard()
    }

    func testValidationKeepsExactDecimalAndRejectsUnsupportedValues() throws {
        let decimal = table().columns[2]
        XCTAssertNoThrow(try EditDraftStore.validate(.text("123456789012345678901234567890.123456789"), column: decimal))
        XCTAssertThrowsError(try EditDraftStore.validate(.null, column: decimal))
        XCTAssertThrowsError(try EditDraftStore.validate(.text("1;SELECT 1"), column: decimal))
        XCTAssertThrowsError(try EditDraftStore.validate(.text("hello\0world"), column: table().columns[1]))
        let small = EditableColumn(index: 0, attributeNumber: 1, name: "small", typeOID: 21, typeSQL: "pg_catalog.int2", nullable: false, kind: .integer)
        XCTAssertNoThrow(try EditDraftStore.validate(.text("32767"), column: small))
        XCTAssertThrowsError(try EditDraftStore.validate(.text("32768"), column: small))
        XCTAssertThrowsError(try EditDraftStore.validate(.text("1.5"), column: small))
        XCTAssertThrowsError(try EditDraftStore.validate(.text(String(repeating: "x", count: 1024 * 1024 + 1)), column: table().columns[1]))
    }

    func testComputedAcknowledgementDoesNotUnlockReadOnlyFields() async throws {
        let metadata = FieldEditorMetadata(classification: .storedComputed, modelField: "record.name", source: "models/record.py:20", revision: "v2")
        let table = table(metadata: metadata), store = EditDraftStore(context: context(table), table: table)
        do { try await store.stage(row: row, columnIndex: 1, value: .text("new")); XCTFail("Expected acknowledgement") } catch { }
        do { try await store.stage(row: row, columnIndex: 1, value: .text("new"), computedAcknowledgement: "v1"); XCTFail("Expected current revision") } catch { }
        try await store.stage(row: row, columnIndex: 1, value: .text("new"), computedAcknowledgement: "v2")
        let plan = try await store.makePlan(mode: .manual, environment: .unknown)
        XCTAssertEqual(plan.table.columns[1].applicationMetadata, metadata)
        do { try await store.stage(row: row, columnIndex: 0, value: .text("2"), computedAcknowledgement: "v2"); XCTFail("Cannot unlock a PK") } catch { }
        await store.discard()
    }

    func testProductionAndUnknownCannotBuildAutoPlan() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        try await store.stage(row: row, columnIndex: 1, value: .text("new"))
        for environment in [ConnectionEnvironment.production, .unknown] {
            do { _ = try await store.makePlan(mode: .auto, environment: environment); XCTFail("Auto is forbidden") } catch { }
        }
        _ = try await store.makePlan(mode: .auto, environment: .development)
        await store.discard()
    }

    func testSharedBudgetRejectsBeforeMutatingAndReleasesAfterDiscard() async throws {
        let table = table(), first = EditDraftStore(context: context(table), table: table), second = EditDraftStore(context: context(table), table: table)
        let reservation = try EditPayloadReservation(bytes: 7 * 1024 * 1024)
        try await first.stage(row: row, columnIndex: 1, value: .text(String(repeating: "a", count: 300_000)))
        do { try await second.stage(row: row, columnIndex: 1, value: .text(String(repeating: "b", count: 300_000))); XCTFail("Global budget must reject") } catch { }
        await assertTrue(second.state().rows.isEmpty)
        await assertEqual(first.state().changedCellCount, 1)
        await first.discard()
        try await second.stage(row: row, columnIndex: 1, value: .text(String(repeating: "b", count: 300_000)))
        await second.discard()
        try reservation.resize(bytes: 0)
    }

    func testThousandSmallRowsFitAndNextEditIsRejectedAtomically() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        for index in 0..<1000 {
            let row = EditableRowSnapshot(rowIndex: index, values: [.text(String(index)), .null, .text("0")], version: "20")
            try await store.stage(row: row, columnIndex: 1, value: .text("New"))
        }
        let extra = EditableRowSnapshot(rowIndex: 1000, values: [.text("1000"), .null, .text("0")], version: "20")
        do { try await store.stage(row: extra, columnIndex: 1, value: .text("New")); XCTFail("Row limit") } catch { }
        await assertEqual(store.state().rows.count, 1000)
        let plan = try await store.makePlan(mode: .manual, environment: .unknown)
        XCTAssertEqual(plan.statements.count, 1000)
        await store.discard()
    }

    func testConflictFreshRowSharesBudgetAndReleasesOnlyAfterLastCopy() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        try await store.stage(row: row, columnIndex: 1, value: .text("Desired"))
        let state = await store.state(), draft = try XCTUnwrap(state.rows.first)
        let otherWork = try EditPayloadReservation(bytes: 7 * 1024 * 1024)
        let current = EditableRowSnapshot(rowIndex: row.rowIndex,
            values: [.text("1"), .text(String(repeating: "f", count: 768 * 1024)), .text("0")], version: "21")
        var original: EditConflict? = EditConflict(row: draft, freshRow: current)
        XCTAssertFalse(try XCTUnwrap(original).comparisonUnavailable)
        XCTAssertNil(original?.comparisonUnavailableReason)
        var copy = original
        original = nil
        try withExtendedLifetime(copy) {
            XCTAssertThrowsError(try EditPayloadReservation(bytes: 400 * 1024))
        }
        copy = nil
        XCTAssertNoThrow(try EditPayloadReservation(bytes: 400 * 1024))
        let exceedsRemainingBudget = EditableRowSnapshot(rowIndex: row.rowIndex,
            values: [.text("1"), .text(String(repeating: "f", count: 1536 * 1024)), .text("0")], version: "22")
        let unavailable = EditConflict(row: draft, freshRow: exceedsRemainingBudget)
        XCTAssertTrue(unavailable.comparisonUnavailable)
        XCTAssertNil(unavailable.freshRow)
        XCTAssertTrue(unavailable.comparisonUnavailableReason?.contains("memory budget") == true)
        try otherWork.resize(bytes: 0)
        await store.discard()
    }

    func testConflictRejectsOversizedComparisonEvenWhenGlobalBudgetIsAvailable() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        try await store.stage(row: row, columnIndex: 1, value: .text("Desired"))
        let state = await store.state(), draft = try XCTUnwrap(state.rows.first)
        let huge = EditableRowSnapshot(rowIndex: row.rowIndex,
            values: [.text("1"), .text(String(repeating: "f", count: EditConflict.maximumFreshRowBytes)), .text("0")], version: "21")
        let conflict = EditConflict(row: draft, freshRow: huge)
        XCTAssertTrue(conflict.comparisonUnavailable)
        XCTAssertNil(conflict.freshValues)
        let missing = EditConflict(row: draft, freshRow: nil)
        XCTAssertTrue(missing.comparisonUnavailable)
        XCTAssertTrue(missing.comparisonUnavailableReason?.contains("visible") == true)
        await store.discard()
    }

    func testTwoVisibleCopiesOfOnePrimaryKeyCannotCreateSeparateDrafts() async throws {
        let table = table(), store = EditDraftStore(context: context(table), table: table)
        try await store.stage(row: row, columnIndex: 1, value: .text("First visible copy"))
        let duplicate = EditableRowSnapshot(rowIndex: 9, values: row.values, version: row.version)
        do {
            try await store.stage(row: duplicate, columnIndex: 1, value: .text("Second visible copy"))
            XCTFail("One physical row must not produce two independent UPDATEs.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("result row 1")) }
        let state = await store.state()
        XCTAssertEqual(state.rows.count, 1)
        XCTAssertEqual(state.rows[0].replacements[1], .text("First visible copy"))
        try await store.stage(row: row, columnIndex: 1, value: row.values[1])
        try await store.stage(row: duplicate, columnIndex: 1, value: .text("Now the only changed copy"))
        await assertEqual(store.state().rows.map(\.id), [9])
        await store.discard()
    }

    func testSnapshotUsesPositionAndValidatesVersion() throws {
        let table = table()
        let fetched: DatabaseRow = [.text("1"), .text("xmin"), .text("2.3"), .text("123")]
        XCTAssertEqual(try table.snapshot(rowIndex: 8, fetchedRow: fetched), EditableRowSnapshot(rowIndex: 8, values: Array(fetched.dropLast()), version: "123"))
        XCTAssertThrowsError(try table.snapshot(rowIndex: 8, fetchedRow: [.text("1"), .null]))
        XCTAssertEqual(table.hiddenVersionIndex, 3)
        XCTAssertTrue(table.selectSQL().contains("xmin::text"))
    }
}

@MainActor private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
@MainActor private func assertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }
@MainActor private func assertEqual<T: Equatable>(_ value: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, expected, file: file, line: line) }
