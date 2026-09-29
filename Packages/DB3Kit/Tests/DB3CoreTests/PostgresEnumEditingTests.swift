import Foundation
import XCTest
import DB3Core
import DB3Postgres

@MainActor
final class PostgresEnumEditingTests: XCTestCase {
    func testUnicodeEnumLabelsStayByteExactThroughStagingAndApply() async throws {
        try await fixture { session, schema in
            let composed = "\u{e9}", decomposed = "e\u{301}"
            let type = "\"\(schema)\".\"Life \"\" Cycle\""
            _ = try await run("ALTER TYPE \(type) ADD VALUE '\(composed)'", session)
            _ = try await run("ALTER TYPE \(type) ADD VALUE '\(decomposed)'", session)
            _ = try await run("UPDATE \(schema).items SET state='\(composed)'", session)
            let (table, row, context) = try await snapshot(session, schema)
            XCTAssertEqual(table.columns[1].valueChoices?.choices.count, 6)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: row, columnIndex: 1, value: .text(decomposed))
            let state = await drafts.state()
            XCTAssertEqual(state.changedCellCount, 1, "A byte-distinct enum key must not coalesce into its original value.")
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            let applied = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown)
            XCTAssertEqual(applied.rows[0]?.values[1], .text(decomposed))
            XCTAssertNotEqual(applied.rows[0]?.values[1], .text(composed))
            await drafts.discard()
        }
    }
    func testCatalogEnumOrderExactLabelsTypedApplyAndEnumForeignKey() async throws {
        try await fixture { session, schema in
            let (table, row, context) = try await snapshot(session, schema)
            let status = table.columns[1], choices = try XCTUnwrap(status.valueChoices)
            XCTAssertNil(status.effectiveReadOnlyReason); XCTAssertEqual(status.kind, .enumeration)
            XCTAssertEqual(choices.choices.map(\.key), ["pending", "done'quoted", "False", ""])
            XCTAssertTrue(choices.isAuthoritative)
            XCTAssertEqual(status.typeSQL, "\"\(schema)\".\"Life \"\" Cycle\"")
            XCTAssertThrowsError(try EditDraftStore.validate(.text("false"), column: status))
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: row, columnIndex: 1, value: .text("done'quoted"))
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            XCTAssertFalse(plan.statements[0].sql.contains("done'quoted")); XCTAssertTrue(plan.statements[0].sql.contains(status.typeSQL))
            let applied = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown)
            XCTAssertEqual(applied.rows[0]?.values[1], .text("done'quoted"))
            XCTAssertEqual(applied.transaction, .inTransaction); XCTAssertFalse(applied.committed)
            _ = try await run("ROLLBACK", session)
            await drafts.discard()
            let fk = try XCTUnwrap(table.foreignKeys.first)
            XCTAssertNil(fk.unavailableReason); XCTAssertEqual(fk.targetColumns[0].kind, .enumeration)
            let lookup = try await PostgresTableEditing.lookup(foreignKey: fk, table: table, search: "Completed", on: session)
            XCTAssertEqual(lookup.candidates.map(\.key), [[.text("done'quoted")]])
            let parentOID = try await records("SELECT '\(schema).states'::regclass::oid::text", session)
            let parent = try await PostgresTableEditing.describe(relationOID: UInt32(parentOID[0][0].displayText)!, on: session)
            XCTAssertNil(parent.readOnlyReason, "Enum primary keys are usable identifiers even though their cells remain read-only.")
            XCTAssertEqual(parent.primaryKeyColumns.first?.kind, .enumeration)
        }
    }

    func testEnumCatalogChangeRejectsOldPreviewAndIncludesInsertedSortPosition() async throws {
        try await fixture { session, schema in
            let (table, row, context) = try await snapshot(session, schema)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: row, columnIndex: 1, value: .text("done'quoted"))
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            _ = try await run("ALTER TYPE \"\(schema)\".\"Life \"\" Cycle\" ADD VALUE 'review' BEFORE 'done''quoted'", session)
            do {
                _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown)
                XCTFail("A changed enum vocabulary must invalidate the preview")
            } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
            let current = try await PostgresTableEditing.describe(relationOID: table.relationOID, on: session)
            XCTAssertNotEqual(current.metadataRevision, table.metadataRevision)
            XCTAssertEqual(current.columns[1].valueChoices?.choices.map(\.key), ["pending", "review", "done'quoted", "False", ""])
            let values = try await records("SELECT state::text FROM \(schema).items", session)
            XCTAssertEqual(values, [[.text("pending")]])
            await drafts.discard()
        }
    }

    func testSourceChoicesAreBoundToLiveIdentityAndMeaningChangesInvalidatePreview() async throws {
        try await fixture { session, schema in
            let provider = EnumTestProvider()
            let (table, row, context) = try await snapshot(session, schema, provider: provider)
            let prepared = await provider.prepared
            XCTAssertEqual(prepared?.schema, schema); XCTAssertEqual(prepared?.relationOID, table.relationOID)
            XCTAssertGreaterThan(prepared?.databaseOID ?? 0, 0); XCTAssertGreaterThan(prepared?.schemaOID ?? 0, 0)
            XCTAssertEqual(table.columns[2].valueChoices?.choices.first?.label, "Readable label")
            XCTAssertTrue(table.columns[1].valueChoices?.isAuthoritative == true, "Source metadata cannot replace a native enum's labels.")
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: row, columnIndex: 2, value: .text("new"))
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            await provider.renameLabel()
            do {
                _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown, metadataProvider: provider)
                XCTFail("Changed source meaning must invalidate an old preview even when its revision string is unchanged")
            } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
            let values = try await records("SELECT source_value FROM \(schema).items", session)
            XCTAssertEqual(values, [[.text("legacy")]])
            await drafts.discard()
        }
    }

    func testSourceChangesWhilePreparingReturnedRowsRollBackEntireApply() async throws {
        try await fixture { session, schema in
            for mode: CommitMode in [.manual, .auto] {
                let provider = EnumTestProvider()
                let (table, row, context) = try await snapshot(session, schema, provider: provider)
                let drafts = EditDraftStore(context: context, table: table)
                try await drafts.stage(row: row, columnIndex: 2, value: .text("new"))
                let plan = try await drafts.makePlan(mode: mode, environment: .development)
                do {
                    _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .development,
                        prepareResult: { _ in await provider.renameLabel() }, metadataProvider: provider)
                    XCTFail("Source changes after UPDATE must still roll back before release or commit")
                } catch { XCTAssertTrue(error.localizedDescription.contains("source changed")) }
                let values = try await records("SELECT source_value FROM \(schema).items", session)
                XCTAssertEqual(values, [[.text("legacy")]])
                let state = await session.transactionState(); XCTAssertEqual(state, .idle)
                await drafts.discard()
            }
        }
    }

    private func snapshot(_ session: PostgresSession, _ schema: String, provider: (any FieldEditorMetadataProvider)? = nil) async throws -> (EditableTable, EditableRowSnapshot, EditSourceContext) {
        let oid = try await records("SELECT '\(schema).items'::regclass::oid::text", session)
        let table = try await PostgresTableEditing.describe(relationOID: UInt32(oid[0][0].displayText)!, on: session, metadataProvider: provider)
        let rows = try await records(table.selectSQL(), session)
        let row = try table.snapshot(rowIndex: 0, fetchedRow: rows[0])
        return (table, row, EditSourceContext(sessionID: UUID(), resultRevision: UUID(), transactionEpoch: 0, relationOID: table.relationOID, metadataRevision: table.metadataRevision))
    }
    private func fixture(_ body: (PostgresSession, String) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DB3_TEST_PORT"].flatMap(Int.init) else { throw XCTSkip("Set DB3_TEST_PORT to use a disposable PostgreSQL fixture.") }
        let session = PostgresSession(), schema = "enum_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        _ = try await session.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, database: env["DB3_TEST_DATABASE"] ?? "postgres", username: env["DB3_TEST_USER"] ?? NSUserName(), tls: .disable), password: env["DB3_TEST_PASSWORD"] ?? "")
        do {
            _ = try await run("CREATE SCHEMA \(schema)", session)
            let type = "\"\(schema)\".\"Life \"\" Cycle\""
            _ = try await run("CREATE TYPE \(type) AS ENUM ('pending','done''quoted','False','')", session)
            _ = try await run("CREATE TABLE \(schema).states (code \(type) PRIMARY KEY, name text)", session)
            _ = try await run("INSERT INTO \(schema).states VALUES ('pending','Pending'),('done''quoted','Completed')", session)
            _ = try await run("CREATE TABLE \(schema).items (id integer PRIMARY KEY, state \(type), source_value text, reference \(type) REFERENCES \(schema).states(code))", session)
            _ = try await run("INSERT INTO \(schema).items VALUES (1,'pending','legacy','pending')", session)
            try await body(session, schema)
            _ = try? await run("ROLLBACK", session); _ = try await run("DROP SCHEMA \(schema) CASCADE", session)
            await session.disconnect()
        } catch {
            _ = try? await run("ROLLBACK", session); _ = try? await run("DROP SCHEMA \(schema) CASCADE", session)
            await session.disconnect(); throw error
        }
    }
    private func run(_ sql: String, _ session: PostgresSession) async throws -> QuerySummary { try await session.execute(sql: sql) { _ in } }
    private func records(_ sql: String, _ session: PostgresSession) async throws -> [DatabaseRow] {
        let collector = EnumTestRows(); _ = try await session.execute(sql: sql) { await collector.consume($0) }; return await collector.rows
    }
}

private actor EnumTestRows {
    var rows: [DatabaseRow] = []
    func consume(_ event: QueryEvent) { if case .rows(let batch) = event { rows += batch.rows } }
}
private actor EnumTestProvider: FieldEditorMetadataProvider {
    struct Prepared: Sendable { let databaseOID: UInt32; let schemaOID: UInt32; let relationOID: UInt32; let schema: String }
    private(set) var prepared: Prepared?
    private var label = "Readable label"
    private var generation = 0
    private var preparedGeneration: [UInt32: Int] = [:]
    func prepare(databaseOID: UInt32, schemaOID: UInt32, relationOID: UInt32, schema: String, table: String, columns: [EditableColumn]) async {
        prepared = Prepared(databaseOID: databaseOID, schemaOID: schemaOID, relationOID: relationOID, schema: schema)
        preparedGeneration[relationOID] = generation
    }
    func validatePreparedMetadata(relationOID: UInt32) async throws {
        guard preparedGeneration[relationOID] == generation else { throw DatabaseError("The project source changed during this apply.") }
    }
    func metadata(relationOID: UInt32, attributeNumber: Int) async -> FieldEditorMetadata? { nil }
    func choices(relationOID: UInt32, attributeNumber: Int) async -> ValueChoiceSet? {
        guard attributeNumber == 2 || attributeNumber == 3 else { return nil }
        return try? ValueChoiceSet(choices: [.init(key: "new", label: label)], source: "Synthetic project model", revision: "same")
    }
    func renameLabel() { label = "Changed meaning"; generation += 1 }
}
