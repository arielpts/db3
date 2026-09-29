import Foundation
import XCTest
import DB3Core
import DB3Postgres

@MainActor
final class PostgresEditingTests: XCTestCase {
    private func connected() async throws -> PostgresSession {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DB3_TEST_PORT"].flatMap(Int.init) else { throw XCTSkip("Set DB3_TEST_PORT to run disposable PostgreSQL editing fixtures.") }
        let session = PostgresSession()
        _ = try await session.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, database: env["DB3_TEST_DATABASE"] ?? "postgres", username: env["DB3_TEST_USER"] ?? NSUserName(), tls: .disable), password: env["DB3_TEST_PASSWORD"] ?? "")
        return session
    }
    @discardableResult private func run(_ sql: String, _ session: PostgresSession) async throws -> QuerySummary {
        try await session.execute(sql: sql) { _ in }
    }
    private func rows(_ sql: String, _ session: PostgresSession) async throws -> [DatabaseRow] {
        let collector = EditingTestCollector()
        _ = try await session.execute(sql: sql) { await collector.consume($0) }
        return await collector.rows
    }
    private func fixture(_ body: (PostgresSession, String) async throws -> Void) async throws {
        let session = try await connected(), schema = "edit_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            try await run("CREATE SCHEMA \(schema)", session)
            try await run("CREATE TABLE \(schema).parent (number integer, code text, name text, PRIMARY KEY(code, number))", session)
            try await run("INSERT INTO \(schema).parent SELECT n, 'key', CASE WHEN n = 3 THEN '50%_\\ literal 🐘' ELSE 'Duplicate ' || (n % 2)::text END FROM generate_series(1,80) n", session)
            try await run("CREATE TABLE \(schema).items (id integer PRIMARY KEY, title text, amount numeric NOT NULL, flag boolean, parent_number integer, parent_code text, calculated numeric GENERATED ALWAYS AS (amount * 2) STORED, identity_value integer GENERATED ALWAYS AS IDENTITY, FOREIGN KEY(parent_code,parent_number) REFERENCES \(schema).parent(code,number))", session)
            try await run("INSERT INTO \(schema).items (id,title,amount,flag,parent_number,parent_code) VALUES (1,'One',10,true,1,'key'),(2,'Two',20,false,2,'key'),(3,NULL,30,NULL,NULL,NULL)", session)
            try await body(session, schema)
            _ = try? await run("ROLLBACK", session)
            try await run("DROP SCHEMA \(schema) CASCADE", session)
            await session.disconnect()
        } catch {
            _ = try? await run("ROLLBACK", session)
            _ = try? await run("DROP SCHEMA \(schema) CASCADE", session)
            await session.disconnect(); throw error
        }
    }
    private func snapshot(_ session: PostgresSession, _ schema: String) async throws -> (EditableTable, [EditableRowSnapshot], EditSourceContext) {
        let identity = try await rows("SELECT '\(schema).items'::regclass::oid::text", session)
        let table = try await PostgresTableEditing.describe(relationOID: UInt32(identity[0][0].displayText)!, on: session)
        let records = try await rows(table.selectSQL(), session)
        let snapshots = try records.enumerated().map { try table.snapshot(rowIndex: $0.offset, fetchedRow: $0.element) }
        return (table, snapshots, EditSourceContext(sessionID: UUID(), resultRevision: UUID(), transactionEpoch: 0, relationOID: table.relationOID, metadataRevision: table.metadataRevision))
    }

    func testMetadataSnapshotParameterizedApplyReturningAndRepeatedEdits() async throws {
        try await fixture { session, schema in
            let (table, rows, context) = try await snapshot(session, schema)
            XCTAssertNil(table.readOnlyReason)
            XCTAssertEqual(table.primaryKeyAttributes, [1])
            XCTAssertTrue(table.columns[0].readOnlyReason?.contains("Primary") == true)
            XCTAssertTrue(table.columns[6].readOnlyReason?.contains("generated") == true)
            XCTAssertTrue(table.columns[7].readOnlyReason?.contains("Identity") == true)
            XCTAssertEqual(table.foreignKeys.first?.localAttributes, [6, 5])
            XCTAssertEqual(table.foreignKeys.first?.targetColumns.map(\.name), ["code", "number"])
            let drafts = EditDraftStore(context: context, table: table)
            let value = "quote ' ; -- 🐘"
            try await drafts.stage(row: rows[0], replacements: [1: .text(value), 2: .text("123456789012345678901234567890.123456789")])
            let plan = try await drafts.makePlan(mode: .manual, environment: .production)
            let result = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .production)
            XCTAssertFalse(result.committed)
            XCTAssertEqual(result.transaction, .inTransaction)
            XCTAssertEqual(result.rows[0]?.values[1], .text(value))
            XCTAssertEqual(result.rows[0]?.values[6], .text("246913578024691357802469135780.246913578"))
            await drafts.discard()
            let next = EditDraftStore(context: context, table: table)
            try await next.stage(row: result.rows[0]!, columnIndex: 1, value: .text("Again"))
            let nextPlan = try await next.makePlan(mode: .manual, environment: .production)
            _ = try await PostgresTableEditing.apply(plan: nextPlan, on: session, currentContext: context, environment: .production)
            try await run("ROLLBACK", session)
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id=1", session), [[.text("One")]])
            await next.discard()
        }
    }

    func testConcurrentWriterConflictPreservesDraftAndEarlierTransactionWork() async throws {
        try await fixture { session, schema in
            let (table, snapshots, context) = try await snapshot(session, schema)
            let other = try await connected()
            try await run("UPDATE \(schema).items SET title='Other writer' WHERE id=2", other)
            await other.disconnect()
            try await run("BEGIN", session)
            try await run("INSERT INTO \(schema).items(id,title,amount) VALUES(10,'Earlier',10)", session)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: snapshots[0], columnIndex: 1, value: .text("First pending"))
            try await drafts.stage(row: snapshots[1], columnIndex: 1, value: .text("Second pending"))
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            do { _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown); XCTFail("Expected conflict") }
            catch let conflict as EditConflict {
                XCTAssertEqual(conflict.row.id, 1)
                XCTAssertEqual(conflict.freshValues?[1], .text("Other writer"))
                XCTAssertNotEqual(conflict.freshRow?.version, snapshots[1].version)
            }
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id IN(1,10) ORDER BY id", session), [[.text("One")], [.text("Earlier")]])
            let state = await drafts.state(); XCTAssertEqual(state.rows.count, 2)
            let transaction = await session.transactionState(); XCTAssertEqual(transaction, .inTransaction)
            await drafts.discard()
        }
    }

    func testProvisionalStoreFailureRollsBackWholeBatch() async throws {
        try await fixture { session, schema in
            let (table, snapshots, context) = try await snapshot(session, schema)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: snapshots[0], columnIndex: 1, value: .text("Changed"))
            let plan = try await drafts.makePlan(mode: .auto, environment: .development)
            do {
                _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .development, prepareResult: { _ in throw DatabaseError("Synthetic result-store quota") })
                XCTFail("Expected quota failure")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic result-store quota")) }
            let transaction = await session.transactionState(); XCTAssertEqual(transaction, .idle)
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id=1", session), [[.text("One")]])
            await drafts.discard()
        }
    }

    func testDevelopmentAutoCommitAndDeferredConstraintFailure() async throws {
        try await fixture { session, schema in
            try await run("ALTER TABLE \(schema).items ADD CONSTRAINT unique_title UNIQUE(title) DEFERRABLE INITIALLY DEFERRED", session)
            let (table, snapshots, context) = try await snapshot(session, schema)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: snapshots[0], columnIndex: 1, value: .text("Committed"))
            let plan = try await drafts.makePlan(mode: .auto, environment: .development)
            // Stale UI preferences cannot bypass the backend environment check.
            do { _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .production); XCTFail("Production guard") } catch { }
            let result = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .development)
            XCTAssertTrue(result.committed)
            XCTAssertEqual(result.transaction, .idle)
            await drafts.discard()
            let failing = EditDraftStore(context: context, table: table)
            try await failing.stage(row: snapshots[1], columnIndex: 1, value: .text("Committed"))
            let failingPlan = try await failing.makePlan(mode: .auto, environment: .development)
            do { _ = try await PostgresTableEditing.apply(plan: failingPlan, on: session, currentContext: context, environment: .development); XCTFail("Deferred unique violation must fail COMMIT") }
            catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "23505") }
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items ORDER BY id", session), [[.text("Committed")], [.text("Two")], [.null]])
            await failing.discard()
        }
    }

    func testForeignKeyLiteralSearchKeysetAndOwnUncommittedRows() async throws {
        try await fixture { session, schema in
            let (table, _, _) = try await snapshot(session, schema), foreignKey = try XCTUnwrap(table.foreignKeys.first)
            XCTAssertNil(foreignKey.unavailableReason)
            let first = try await PostgresTableEditing.lookup(foreignKey: foreignKey, table: table, search: "", on: session)
            XCTAssertEqual(first.candidates.count, 50)
            XCTAssertNotNil(first.nextCursor)
            let second = try await PostgresTableEditing.lookup(foreignKey: foreignKey, table: table, search: "", cursor: first.nextCursor, on: session)
            XCTAssertEqual(second.candidates.count, 30)
            XCTAssertNil(second.nextCursor)
            XCTAssertTrue(Set(first.candidates.map(\.id)).isDisjoint(with: Set(second.candidates.map(\.id))))
            let literal = try await PostgresTableEditing.lookup(foreignKey: foreignKey, table: table, search: "%_\\", on: session)
            XCTAssertEqual(literal.candidates.map(\.key), [[.text("key"), .text("3")]])
            let unicode = try await PostgresTableEditing.lookup(foreignKey: foreignKey, table: table, search: "🐘", on: session)
            XCTAssertEqual(unicode.candidates.map(\.key), [[.text("key"), .text("3")]])
            try await run("BEGIN", session)
            try await run("INSERT INTO \(schema).parent VALUES(100,'new','Only uncommitted')", session)
            let own = try await PostgresTableEditing.lookup(foreignKey: foreignKey, table: table, search: "uncommitted", on: session)
            XCTAssertEqual(own.candidates.map(\.key), [[.text("new"), .text("100")]])
            let state = await session.transactionState(); XCTAssertEqual(state, .inTransaction)
        }
    }

    func testUniqueKeyLookupTargetDeletionPreservesEarlierWorkAndDrafts() async throws {
        try await fixture { session, schema in
            try await run("CREATE TABLE \(schema).unique_target (id integer PRIMARY KEY, external_code text NOT NULL UNIQUE, name text)", session)
            try await run("INSERT INTO \(schema).unique_target VALUES (901,'chosen-code','Unique target 🐘')", session)
            try await run("ALTER TABLE \(schema).items ADD COLUMN external_reference text REFERENCES \(schema).unique_target(external_code)", session)
            let (table, snapshots, context) = try await snapshot(session, schema)
            let foreignKey = try XCTUnwrap(table.foreignKeys.first { $0.targetTable == "unique_target" })
            XCTAssertEqual(foreignKey.targetColumns.map(\.name), ["external_code"])
            XCTAssertNil(foreignKey.unavailableReason)
            let column = try XCTUnwrap(table.columns.first { foreignKey.localAttributes.contains($0.attributeNumber) })
            try await run("BEGIN", session)
            try await run("INSERT INTO \(schema).items(id,title,amount) VALUES(10,'Earlier user work',10)", session)
            let page = try await PostgresTableEditing.lookup(foreignKey: foreignKey, table: table, search: "🐘", on: session)
            let chosen = try XCTUnwrap(page.candidates.first)
            XCTAssertEqual(chosen.key, [.text("chosen-code")], "Stage the referenced UNIQUE value, not the target's unrelated primary key.")
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: snapshots[0], columnIndex: 1, value: .text("Must roll back with failed FK update"))
            try await drafts.stage(row: snapshots[1], replacements: [column.index: chosen.key[0]])
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            let deleting = try await connected()
            do {
                try await run("DELETE FROM \(schema).unique_target WHERE external_code='chosen-code'", deleting)
                await deleting.disconnect()
            } catch {
                await deleting.disconnect(); throw error
            }
            do {
                _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown)
                XCTFail("The selected target was deleted before Apply; PostgreSQL must reject the FK.")
            } catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "23503") }
            try await assertDatabaseRows(self.rows("SELECT title, external_reference FROM \(schema).items WHERE id IN(1,2,10) ORDER BY id", session),
                [[.text("One"), .null], [.text("Two"), .null], [.text("Earlier user work"), .null]])
            let state = await session.transactionState(); XCTAssertEqual(state, .inTransaction)
            let pending = await drafts.state()
            XCTAssertEqual(pending.rows.count, 2)
            XCTAssertEqual(pending.rows.first { $0.id == snapshots[1].rowIndex }?.replacements[column.index], .text("chosen-code"))
            await drafts.discard()
        }
    }

    func testProjectedAliasesExpressionsAndReadonlyDomainUseVerifiedCurrentBaseline() async throws {
        try await fixture { session, schema in
            try await run("CREATE DOMAIN \(schema).positive_integer AS integer CHECK (VALUE > 0)", session)
            try await run("ALTER TABLE \(schema).items ADD COLUMN domain_value \(schema).positive_integer", session)
            try await run("UPDATE \(schema).items SET domain_value=id*10", session)
            let (table, _, context) = try await snapshot(session, schema)
            let collector = EditingTestCollector()
            _ = try await session.execute(sql: "SELECT domain_value, title AS renamed, 42 AS expression, id FROM \(schema).items WHERE id=1") { await collector.consume($0) }
            let columns = await collector.columns, projectedRows = await collector.rows
            let projected = try XCTUnwrap(projectedRows.first)
            let projection = try ResultEditProjection(table: table, columns: columns)
            XCTAssertEqual(projection.resultToTable, [8, 1, nil, 0])
            XCTAssertTrue(projection.hasExpressions)
            XCTAssertNotNil(table.columns[8].effectiveReadOnlyReason)
            XCTAssertEqual(columns[0].typeOID, 23, "libpq unwraps a domain to its wire base type.")
            let verified = try await PostgresTableEditing.verifyProjectedRow(table: table, projection: projection,
                rowIndex: 7, row: projected, on: session)
            XCTAssertEqual(verified.rowIndex, 7)
            XCTAssertEqual(verified.values[0], .text("1"))
            XCTAssertEqual(verified.values[8], .text("10"))
            XCTAssertNotNil(UInt32(verified.version))
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: verified, columnIndex: 1, value: .text("Edited through alias"))
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            let applied = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown)
            let result = try XCTUnwrap(applied.rows[7])
            XCTAssertEqual(try projection.projectedRow(applying: result, to: projected),
                [.text("10"), .text("Edited through alias"), .text("42"), .text("1")])
            await drafts.discard()
        }
    }

    func testProjectedVerificationRejectsConcurrentVisibleChangesAndPreservesEarlierWork() async throws {
        try await fixture { session, schema in
            let (table, _, _) = try await snapshot(session, schema)
            let collector = EditingTestCollector()
            _ = try await session.execute(sql: "SELECT title, id FROM \(schema).items WHERE id=1") { await collector.consume($0) }
            let columns = await collector.columns, projectedRows = await collector.rows
            let projected = try XCTUnwrap(projectedRows.first)
            let projection = try ResultEditProjection(table: table, columns: columns)
            try await run("BEGIN", session)
            try await run("INSERT INTO \(schema).items(id,title,amount) VALUES(10,'Earlier work',10)", session)
            let other = try await connected()
            do {
                try await run("UPDATE \(schema).items SET amount=200 WHERE id=1", other)
                let adopted = try await PostgresTableEditing.verifyProjectedRow(table: table, projection: projection,
                    rowIndex: 0, row: projected, on: session)
                XCTAssertEqual(adopted.values[2], .text("200"), "An unprojected value comes from the checked current row, not a guessed original xmin.")
                try await run("UPDATE \(schema).items SET title='Concurrent visible change' WHERE id=1", other)
                await other.disconnect()
            } catch {
                await other.disconnect(); throw error
            }
            do {
                _ = try await PostgresTableEditing.verifyProjectedRow(table: table, projection: projection,
                    rowIndex: 0, row: projected, on: session)
                XCTFail("The original displayed values must still match before adopting a current baseline.")
            } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
            let state = await session.transactionState(); XCTAssertEqual(state, .inTransaction)
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id=10", session), [[.text("Earlier work")]])
        }
    }

    func testProjectedTextVerificationUsesExactCollationForReadonlyCaseInsensitiveColumn() async throws {
        try await fixture { session, schema in
            let icu = try await rows("SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_collation WHERE collprovider='i')::text", session)
            guard icu.first?.first == .text("true") else { throw XCTSkip("This disposable PostgreSQL build has no ICU collations.") }
            try await run("CREATE COLLATION \(schema).case_insensitive (provider=icu, locale='und-u-ks-level2', deterministic=false)", session)
            try await run("ALTER TABLE \(schema).items ALTER COLUMN title TYPE text COLLATE \(schema).case_insensitive", session)
            let (table, _, _) = try await snapshot(session, schema)
            XCTAssertTrue(table.columns[1].readOnlyReason?.contains("Nondeterministic") == true)
            let collector = EditingTestCollector()
            _ = try await session.execute(sql: "SELECT id, title, amount FROM \(schema).items WHERE id=1") { await collector.consume($0) }
            let columns = await collector.columns, projectedRows = await collector.rows
            let projected = try XCTUnwrap(projectedRows.first), projection = try ResultEditProjection(table: table, columns: columns)
            _ = try await PostgresTableEditing.verifyProjectedRow(table: table, projection: projection,
                rowIndex: 0, row: projected, on: session)
            let other = try await connected()
            do {
                try await run("UPDATE \(schema).items SET title='oNE' WHERE id=1", other)
                await other.disconnect()
            } catch { await other.disconnect(); throw error }
            do {
                _ = try await PostgresTableEditing.verifyProjectedRow(table: table, projection: projection,
                    rowIndex: 0, row: projected, on: session)
                XCTFail("A case-insensitive table collation must not hide changes to original displayed values.")
            } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        }
    }

    func testCancellationRollsBackEntireBatchAndPreservesEarlierWork() async throws {
        try await fixture { session, schema in
            try await run("CREATE FUNCTION \(schema).slow_update() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id=2 THEN PERFORM pg_sleep(30); END IF; RETURN NEW; END $$", session)
            try await run("CREATE TRIGGER slow_update BEFORE UPDATE ON \(schema).items FOR EACH ROW EXECUTE FUNCTION \(schema).slow_update()", session)
            let (table, snapshots, context) = try await snapshot(session, schema)
            try await run("BEGIN", session)
            try await run("INSERT INTO \(schema).items(id,title,amount) VALUES(10,'Earlier',10)", session)
            let drafts = EditDraftStore(context: context, table: table)
            for row in snapshots.prefix(2) { try await drafts.stage(row: row, columnIndex: 1, value: .text("Changed")) }
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            let applying = Task { try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown) }
            try await Task.sleep(for: .milliseconds(200)); applying.cancel()
            do { _ = try await applying.value; XCTFail("Expected cancelled batch") } catch { }
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id IN(1,2,10) ORDER BY id", session), [[.text("One")], [.text("Two")], [.text("Earlier")]])
            let state = await session.transactionState(); XCTAssertEqual(state, .inTransaction)
            await drafts.discard()
        }
    }

    func testReclassificationBeforeAutomaticCommitRollsBack() async throws {
        try await fixture { session, schema in
            let (table, snapshots, context) = try await snapshot(session, schema)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: snapshots[0], columnIndex: 1, value: .text("Must roll back"))
            let plan = try await drafts.makePlan(mode: .auto, environment: .development)
            let coordinator = ManagedSession(session: session, environment: .development)
            do {
                _ = try await coordinator.withExclusiveOperation { connection in
                    try await PostgresTableEditing.apply(plan: plan, on: connection, currentContext: context, environment: .development,
                        prepareResult: { _ in coordinator.restrictEnvironment(to: .production) },
                        authorizeAutoCommit: { try coordinator.authorizeAutoCommit() })
                }
                XCTFail("The late policy check must reject automatic COMMIT")
            } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("development")) }
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id=1", session), [[.text("One")]])
            let state = await session.transactionState(); XCTAssertEqual(state, .idle)
            await drafts.discard()
        }
    }

    func testRowLevelSecurityConflictAndDeniedLookupPreserveTransaction() async throws {
        try await fixture { session, schema in
            let role = schema + "_role"
            try await run("CREATE ROLE \(role)", session)
            do {
                try await run("GRANT USAGE ON SCHEMA \(schema) TO \(role)", session)
                try await run("GRANT SELECT, UPDATE ON \(schema).items TO \(role)", session)
                try await run("ALTER TABLE \(schema).items ENABLE ROW LEVEL SECURITY", session)
                try await run("CREATE POLICY restricted ON \(schema).items USING (id <> 2)", session)
                let (table, snapshots, context) = try await snapshot(session, schema)
                try await run("SET ROLE \(role)", session)
                let described = try await PostgresTableEditing.describe(relationOID: table.relationOID, on: session)
                XCTAssertNotNil(described.foreignKeys.first?.unavailableReason)
                // The role change itself requires a new source context in the app.
                // This fixture isolates the backend's final RLS/rowcount protection.
                let newContext = EditSourceContext(sessionID: context.sessionID, resultRevision: context.resultRevision,
                    transactionEpoch: context.transactionEpoch, relationOID: table.relationOID, metadataRevision: described.metadataRevision)
                let drafts = EditDraftStore(context: newContext, table: described)
                try await drafts.stage(row: snapshots[1], columnIndex: 1, value: .text("Blocked"))
                let plan = try await drafts.makePlan(mode: .manual, environment: .production)
                try await run("BEGIN", session)
                do { _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: newContext, environment: .production); XCTFail("RLS must prevent the update") }
                catch let conflict as EditConflict { XCTAssertNil(conflict.freshRow) }
                let state = await session.transactionState(); XCTAssertEqual(state, .inTransaction)
                do { _ = try await PostgresTableEditing.lookup(foreignKey: described.foreignKeys[0], table: described, search: "", on: session); XCTFail("Denied relationship") }
                catch { XCTAssertTrue(error.localizedDescription.contains("role")) }
                _ = try await run("SELECT 1", session)
                await drafts.discard()
                try await run("ROLLBACK", session)
                try await run("RESET ROLE", session)
                try await run("DROP OWNED BY \(role)", session)
                try await run("DROP ROLE \(role)", session)
            } catch {
                _ = try? await run("ROLLBACK", session)
                _ = try? await run("RESET ROLE", session)
                _ = try? await run("DROP OWNED BY \(role)", session)
                _ = try? await run("DROP ROLE \(role)", session)
                throw error
            }
        }
    }

    func testSchemaChangeAndTriggerSuppressionNeverOverwrite() async throws {
        try await fixture { session, schema in
            let (table, snapshots, context) = try await snapshot(session, schema)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: snapshots[0], columnIndex: 1, value: .text("Changed"))
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            try await run("ALTER TABLE \(schema).items ALTER COLUMN title TYPE varchar(200)", session)
            do { _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown); XCTFail("Schema fingerprint must change") }
            catch { XCTAssertTrue(error.localizedDescription.contains("definition")) }
            await drafts.discard()
            try await run("CREATE FUNCTION \(schema).suppress() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$", session)
            try await run("CREATE TRIGGER suppress BEFORE UPDATE ON \(schema).items FOR EACH ROW EXECUTE FUNCTION \(schema).suppress()", session)
            let (newTable, newRows, newContext) = try await snapshot(session, schema)
            let blocked = EditDraftStore(context: newContext, table: newTable)
            try await blocked.stage(row: newRows[0], columnIndex: 1, value: .text("Suppressed"))
            let blockedPlan = try await blocked.makePlan(mode: .manual, environment: .unknown)
            do { _ = try await PostgresTableEditing.apply(plan: blockedPlan, on: session, currentContext: newContext, environment: .unknown); XCTFail("Zero returned rows is a conflict") }
            catch is EditConflict { }
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id=1", session), [[.text("One")]])
            await blocked.discard()
        }
    }
}
extension PostgresEditingTests {
    func testInsertDefaultsNullEmptyReturningAndManualPrimaryKey() async throws {
        try await fixture { session, schema in
            try await run("ALTER TABLE \(schema).items ALTER COLUMN title SET DEFAULT 'Database default'", session)
            let (table, _, context) = try await snapshot(session, schema)
            XCTAssertNil(table.columns[0].effectiveInsertReadOnlyReason)
            XCTAssertTrue(table.columns[1].hasDefault)
            XCTAssertNotNil(table.columns[6].effectiveInsertReadOnlyReason)
            XCTAssertNotNil(table.columns[7].effectiveInsertReadOnlyReason)
            let drafts = EditDraftStore(context: context, table: table)
            for index in 0..<3 {
                try await drafts.addInsert(rowIndex: index + 3)
                try await drafts.stageInsert(rowIndex: index + 3, replacements: [0: .text(String(index + 4)), 2: .text("12.5")])
            }
            try await drafts.stageInsert(rowIndex: 4, columnIndex: 1, value: .null)
            try await drafts.stageInsert(rowIndex: 5, columnIndex: 1, value: .text(""))
            let plan = try await drafts.makePlan(mode: .manual, environment: .production)
            let applied = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .production)
            XCTAssertFalse(applied.committed)
            XCTAssertEqual(applied.rows[3]?.values[1], .text("Database default"))
            XCTAssertEqual(applied.rows[4]?.values[1], .null)
            XCTAssertEqual(applied.rows[5]?.values[1], .text(""))
            XCTAssertEqual(applied.rows[3]?.values[6], .text("25.0"))
            XCTAssertNotNil(applied.rows[3]?.values[7])
            XCTAssertNotNil(applied.rows[3].flatMap { UInt32($0.version) })
            try await run("ROLLBACK", session)
            try await assertDatabaseRows(self.rows("SELECT count(*)::text FROM \(schema).items", session), [[.text("3")]])
            await drafts.discard()
        }
    }

    func testAllDefaultInsertGeneratedPrimaryKeyAndAutomaticCommit() async throws {
        try await fixture { session, schema in
            try await run("ALTER TABLE \(schema).items ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (START WITH 100)", session)
            try await run("ALTER TABLE \(schema).items ALTER COLUMN amount SET DEFAULT 9", session)
            let (table, _, context) = try await snapshot(session, schema)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.addInsert(rowIndex: 3)
            let plan = try await drafts.makePlan(mode: .auto, environment: .development)
            XCTAssertTrue(plan.statements[0].sql.contains("DEFAULT VALUES"))
            let applied = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .development)
            XCTAssertTrue(applied.committed)
            XCTAssertEqual(applied.rows[3]?.values[0], .text("100"))
            XCTAssertEqual(applied.rows[3]?.values[2], .text("9"))
            XCTAssertEqual(applied.rows[3]?.values[6], .text("18"))
            try await assertDatabaseRows(self.rows("SELECT id::text FROM \(schema).items WHERE id=100", session), [[.text("100")]])
            await drafts.discard()
        }
    }

    func testDuplicateInsertRollsBackMixedBatchAndKeepsEarlierWork() async throws {
        try await fixture { session, schema in
            let (table, snapshots, context) = try await snapshot(session, schema)
            try await run("BEGIN", session)
            try await run("INSERT INTO \(schema).items(id,title,amount) VALUES(10,'Earlier',10)", session)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: snapshots[0], columnIndex: 1, value: .text("Must roll back"))
            try await drafts.addInsert(rowIndex: 3)
            try await drafts.stageInsert(rowIndex: 3, replacements: [0: .text("4"), 2: .text("4")])
            try await drafts.addInsert(rowIndex: 4)
            try await drafts.stageInsert(rowIndex: 4, replacements: [0: .text("2"), 2: .text("4")])
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            do { _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown); XCTFail("Duplicate PK must fail") }
            catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "23505") }
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id IN (1,4,10) ORDER BY id", session), [[.text("One")], [.text("Earlier")]])
            let state = await session.transactionState(); XCTAssertEqual(state, .inTransaction)
            let pending = await drafts.state(); XCTAssertEqual(pending.changedRowCount, 3)
            await drafts.discard()
        }
    }

    func testSuppressedInsertRollsBackMixedBatch() async throws {
        try await fixture { session, schema in
            try await run("CREATE FUNCTION \(schema).suppress_insert() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id=5 THEN RETURN NULL; END IF; RETURN NEW; END $$", session)
            try await run("CREATE TRIGGER suppress_insert BEFORE INSERT ON \(schema).items FOR EACH ROW EXECUTE FUNCTION \(schema).suppress_insert()", session)
            let (table, snapshots, context) = try await snapshot(session, schema)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.stage(row: snapshots[0], columnIndex: 1, value: .text("Must roll back"))
            for index in 3...4 {
                try await drafts.addInsert(rowIndex: index)
                try await drafts.stageInsert(rowIndex: index, replacements: [0: .text(String(index + 1)), 2: .text("4")])
            }
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            do { _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown); XCTFail("Suppressed insert must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("exactly one row")) }
            try await assertDatabaseRows(self.rows("SELECT title FROM \(schema).items WHERE id IN (1,4,5) ORDER BY id", session), [[.text("One")]])
            let pending = await drafts.state(); XCTAssertEqual(pending.changedRowCount, 3)
            await drafts.discard()
        }
    }

    func testColumnInsertPermissionWithoutUpdateAndRevocationRevalidation() async throws {
        try await fixture { session, schema in
            let role = schema + "_insert_role"
            try await run("CREATE ROLE \(role)", session)
            do {
                try await run("GRANT USAGE ON SCHEMA \(schema) TO \(role)", session)
                try await run("GRANT SELECT ON \(schema).items TO \(role)", session)
                try await run("GRANT INSERT(id, amount, title) ON \(schema).items TO \(role)", session)
                try await run("SET ROLE \(role)", session)
                let (table, _, context) = try await snapshot(session, schema)
                XCTAssertNil(table.insertReadOnlyReason)
                XCTAssertNotNil(table.columns[1].effectiveReadOnlyReason)
                XCTAssertNil(table.columns[1].effectiveInsertReadOnlyReason)
                XCTAssertNotNil(table.columns[3].effectiveInsertReadOnlyReason)
                let drafts = EditDraftStore(context: context, table: table)
                try await drafts.addInsert(rowIndex: 3)
                try await drafts.stageInsert(rowIndex: 3, replacements: [0: .text("4"), 2: .text("4")])
                let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
                let applied = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown)
                XCTAssertEqual(applied.rows[3]?.values[0], .text("4"))
                try await run("ROLLBACK", session)
                try await run("RESET ROLE", session)
                try await run("REVOKE INSERT(amount) ON \(schema).items FROM \(role)", session)
                try await run("SET ROLE \(role)", session)
                do { _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown); XCTFail("Permission change must invalidate preview") }
                catch { XCTAssertTrue(error.localizedDescription.contains("definition")) }
                await drafts.discard()
                try await run("RESET ROLE", session)
                try await run("DROP OWNED BY \(role)", session)
                try await run("DROP ROLE \(role)", session)
            } catch {
                _ = try? await run("ROLLBACK", session)
                _ = try? await run("RESET ROLE", session)
                _ = try? await run("DROP OWNED BY \(role)", session)
                _ = try? await run("DROP ROLE \(role)", session)
                throw error
            }
        }
    }

    func testInsertDefaultChangeInvalidatesPreview() async throws {
        try await fixture { session, schema in
            let (table, _, context) = try await snapshot(session, schema)
            let drafts = EditDraftStore(context: context, table: table)
            try await drafts.addInsert(rowIndex: 3)
            try await drafts.stageInsert(rowIndex: 3, replacements: [0: .text("4"), 2: .text("4")])
            let plan = try await drafts.makePlan(mode: .manual, environment: .unknown)
            try await run("ALTER TABLE \(schema).items ALTER COLUMN title SET DEFAULT 'Changed after review'", session)
            do { _ = try await PostgresTableEditing.apply(plan: plan, on: session, currentContext: context, environment: .unknown); XCTFail("Default must be revalidated") }
            catch { XCTAssertTrue(error.localizedDescription.contains("definition")) }
            try await assertDatabaseRows(self.rows("SELECT count(*)::text FROM \(schema).items", session), [[.text("3")]])
            await drafts.discard()
        }
    }
}
private actor EditingTestCollector {
    var rows: [DatabaseRow] = []
    var columns: [DatabaseColumn] = []
    func consume(_ event: QueryEvent) {
        switch event {
        case .rows(let batch): rows += batch.rows
        case .columns(let value): columns = value
        case .notice: break
        }
    }
}

@MainActor private func assertDatabaseRows(_ rows: [DatabaseRow], _ expected: [DatabaseRow], file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(rows, expected, file: file, line: line) }
