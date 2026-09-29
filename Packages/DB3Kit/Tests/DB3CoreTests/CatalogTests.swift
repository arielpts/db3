import Foundation
import XCTest
import DB3Core
import DB3Postgres

final class CatalogTypesTests: XCTestCase {
    func testSchemaFilterParticipatesInQueryIdentityAndDefaultsToAllSchemas() {
        XCTAssertNil(CatalogQuery().schema)
        XCTAssertNotEqual(CatalogQuery(schema: "public"), CatalogQuery(schema: "Public"))
        XCTAssertNotEqual(CatalogQuery(schema: "public"), CatalogQuery())
        let page = CatalogPage(objects: [], nextCursor: nil,
                               database: CatalogDatabaseIdentity(oid: 1, name: "postgres"), generation: UUID())
        XCTAssertTrue(page.schemas.isEmpty)
        XCTAssertFalse(page.schemasTruncated)
    }

    func testQualifiedIdentifiersAreQuotedByComponentAndNeverSplitOnDots() {
        let source = CatalogSource(profile: ConnectionProfile(), revision: UUID())
        let object = DatabaseObject(
            id: DatabaseObjectID(source: source, databaseOID: 10, relationOID: 20, generation: UUID()),
            schemaOID: 11, schema: "Sa\"les", name: "Order.Items", kind: .table
        )
        XCTAssertEqual(object.quotedQualifiedName, "\"Sa\"\"les\".\"Order.Items\"")
        XCTAssertEqual(object.selectSQL, "SELECT *\nFROM \"Sa\"\"les\".\"Order.Items\"\nLIMIT 1000;")
        XCTAssertGreaterThan(object.byteCount, object.qualifiedName.utf8.count)
    }

    func testIdentityIsScopedToEndpointAuthenticationDatabaseAndGeneration() {
        let profile = ConnectionProfile(), revision = UUID(), generation = UUID()
        let source = CatalogSource(profile: profile, revision: revision)
        let original = DatabaseObjectID(source: source, databaseOID: 12, relationOID: 99, generation: generation)
        var otherEndpoint = profile; otherEndpoint.host = "another.example"
        let variants = [
            DatabaseObjectID(source: CatalogSource(profile: otherEndpoint, revision: revision), databaseOID: 12, relationOID: 99, generation: generation),
            DatabaseObjectID(source: CatalogSource(profile: profile, revision: UUID()), databaseOID: 12, relationOID: 99, generation: generation),
            DatabaseObjectID(source: source, databaseOID: 13, relationOID: 99, generation: generation),
            DatabaseObjectID(source: source, databaseOID: 12, relationOID: 99, generation: UUID())
        ]
        for variant in variants { XCTAssertNotEqual(original, variant) }
    }
}

/// These fixtures run only in the disposable PostgreSQL server started by
/// Scripts/test.sh --integration. No saved application connection is read.
@MainActor
final class CatalogPostgresTests: XCTestCase {
    private func settings() throws -> (ConnectionProfile, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["DB3_TEST_PORT"], let port = Int(value) else {
            throw XCTSkip("Set DB3_TEST_PORT to run disposable catalog integration tests.")
        }
        return (ConnectionProfile(host: environment["DB3_TEST_HOST"] ?? "127.0.0.1", port: port,
                                  database: environment["DB3_TEST_DATABASE"] ?? "postgres",
                                  username: environment["DB3_TEST_USER"] ?? NSUserName(), tls: .disable),
                environment["DB3_TEST_PASSWORD"] ?? "")
    }

    private func run(_ sql: String, on session: PostgresSession) async throws {
        _ = try await session.execute(sql: sql) { _ in }
    }

    private func dropLargeFixtureViews(schema: String, on session: PostgresSession) async throws {
        // Drop in separate transactions so the fixture's teardown itself does
        // not exhaust PostgreSQL's default shared lock table.
        for start in stride(from: 1, through: 5500, by: 250) {
            let names = (start...min(start + 249, 5500)).map { schema + ".view" + String(format: "%05d", $0) }
            try await run("DROP VIEW IF EXISTS " + names.joined(separator: ", "), on: session)
        }
    }

    private func withFixture(_ body: (PostgresSession, CatalogSource, String, String) async throws -> Void) async throws {
        let (profile, password) = try settings()
        let setup = PostgresSession()
        _ = try await setup.connect(profile: profile, password: password)
        let schema = "db3cat" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await run("CREATE SCHEMA \(schema)", on: setup)
        do {
            try await body(setup, CatalogSource(profile: profile, revision: UUID()), password, schema)
        } catch {
            try? await run("ROLLBACK", on: setup)
            try? await run("DROP SCHEMA \(schema) CASCADE", on: setup)
            await setup.disconnect()
            throw error
        }
        try await run("DROP SCHEMA \(schema) CASCADE", on: setup)
        await setup.disconnect()
    }

    func testNamespaceMembershipIsAppliedBeforePaginationAndRecreationDoesNotReuseOverrides() async throws {
        try await withFixture { session, source, password, schema in
            try await run("CREATE TABLE \(schema).aaa_unclassified (id integer)", on: session)
            try await run("CREATE TABLE \(schema).zzz_target (id integer)", on: session)
            let service = PostgresCatalogService()
            let membership = CatalogMembership(schema: schema, relation: "zzz_target")
            let filter = CatalogNamespaceFilter(included: [membership])
            let page = try await service.page(source: source, password: password, query: CatalogQuery(schema: schema, limit: 1, namespaceFilter: filter))
            XCTAssertEqual(page.objects.map(\.name), ["zzz_target"])
            XCTAssertNil(page.nextCursor)
            let target = try XCTUnwrap(page.objects.first)
            XCTAssertFalse(target.identityToken.isEmpty)
            let identity = CatalogMembership(schema: schema, relation: "zzz_target", oid: target.id.relationOID, token: target.identityToken)
            let unclassified = try await service.page(source: source, password: password,
                query: CatalogQuery(schema: schema, namespaceFilter: .init(excluded: [identity])))
            XCTAssertEqual(unclassified.objects.map(\.name), ["aaa_unclassified"])
            try await run("DROP TABLE \(schema).zzz_target", on: session)
            try await run("CREATE TABLE \(schema).zzz_target (id integer)", on: session)
            let stale = try await service.page(source: source, password: password,
                query: CatalogQuery(schema: schema, namespaceFilter: .init(included: [identity])))
            XCTAssertTrue(stale.objects.isEmpty)
            let replacement = try await service.page(source: source, password: password,
                query: CatalogQuery(search: "zzz", schema: schema, namespaceFilter: .init(excluded: [identity])))
            XCTAssertEqual(replacement.objects.map(\.name), ["zzz_target"])
            let noMembership = try await service.page(source: source, password: password,
                query: CatalogQuery(schema: schema, namespaceFilter: .init(included: [])))
            XCTAssertTrue(noMembership.objects.isEmpty)
            await service.disconnect()
        }
    }

    func testBoundParametersPreserveNullUnicodeAndSQLSyntaxAsValues() async throws {
        try await withFixture { session, _, _, _ in
            let special = "x'); SELECT pg_sleep(30); -- %_\\ 🐘"
            let collector = CatalogTestRows()
            _ = try await session.execute(sql: "SELECT $1::text, $2::text, $3::text, $4::integer", parameters: [special, nil, "", "42"]) {
                await collector.consume($0)
            }
            let rows = await collector.rows
            XCTAssertEqual(rows, [[.text(special), .null, .text(""), .text("42")]])
            do {
                _ = try await session.execute(sql: "SELECT $1::text; SELECT 2", parameters: ["data"]) { _ in }
                XCTFail("Parameters must not permit a multi-statement script.")
            } catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "42601") }
            do {
                _ = try await session.execute(sql: "SELECT $1::text", parameters: ["before\0after"]) { _ in }
                XCTFail("Embedded NUL must be rejected before libpq truncates it.")
            } catch let error as DatabaseError { XCTAssertTrue(error.message.contains("NUL")) }
            let sleeping = Task {
                try await session.execute(sql: "SELECT pg_sleep($1::double precision)", parameters: ["30"]) { _ in }
            }
            try await Task.sleep(for: .milliseconds(80))
            sleeping.cancel()
            do { _ = try await sleeping.value; XCTFail("The exact bound operation must cancel.") } catch { }
            _ = try await session.execute(sql: "SELECT $1::integer", parameters: ["7"]) { _ in }
        }
    }

    func testStartupPasswordErrorsHaveAuthStateButDatabaseErrorsDoNot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portValue = environment["DB3_TEST_AUTH_PORT"], let port = Int(portValue),
              let username = environment["DB3_TEST_AUTH_USER"], let password = environment["DB3_TEST_AUTH_PASSWORD"] else {
            throw XCTSkip("Set disposable SCRAM fixture variables to test startup credential prompts.")
        }
        let profile = ConnectionProfile(host: "127.0.0.1", port: port, database: "postgres", username: username, tls: .disable)
        for attemptedPassword in ["", "incorrect-fixture-password"] {
            let session = PostgresSession()
            do {
                _ = try await session.connect(profile: profile, password: attemptedPassword)
                XCTFail("Missing and incorrect credentials must fail.")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.sqlState?.prefix(2), "28")
                XCTAssertFalse(error.message.contains(password))
            }
            await session.disconnect()
        }
        let session = PostgresSession()
        var missingDatabase = profile; missingDatabase.database = "db3_database_does_not_exist"
        do {
            _ = try await session.connect(profile: missingDatabase, password: password)
            XCTFail("Unknown database must fail.")
        } catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "3D000") }
        _ = try await session.connect(profile: profile, password: password)
        await session.disconnect()
        var requiresTLS = profile; requiresTLS.tls = .require
        do {
            _ = try await session.connect(profile: requiresTLS, password: password)
            XCTFail("The SCRAM-only fixture has no TLS server configured.")
        } catch let error as DatabaseError { XCTAssertNotEqual(error.sqlState?.prefix(2), "28") }
        await session.disconnect()
    }

    func testRelationKindsPartitionsCrossSchemaAndMaterializedState() async throws {
        try await withFixture { setup, source, password, schema in
            for sql in [
                "CREATE TABLE \(schema).ordinary (id integer PRIMARY KEY)",
                "CREATE TABLE \(schema).partitioned (id integer) PARTITION BY RANGE (id)",
                "CREATE TABLE \(schema).child PARTITION OF \(schema).partitioned FOR VALUES FROM (0) TO (10)",
                "CREATE VIEW \(schema).ordinary_view AS SELECT 1 AS id",
                "CREATE MATERIALIZED VIEW \(schema).populated AS SELECT 1 AS id",
                "CREATE MATERIALIZED VIEW \(schema).unpopulated AS SELECT 1 AS id WITH NO DATA",
                "CREATE SEQUENCE \(schema).excluded_sequence",
                "CREATE TYPE \(schema).excluded_composite AS (a integer)",
                "CREATE TEMP TABLE db3_catalog_excluded_temp(id integer)"
            ] { try await run(sql, on: setup) }
            let service = PostgresCatalogService()
            do {
                let page = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                let objects = Dictionary(uniqueKeysWithValues: page.objects.map { ($0.name, $0) })
                XCTAssertEqual(Set(objects.keys), ["ordinary", "partitioned", "child", "ordinary_view", "populated", "unpopulated"])
                XCTAssertEqual(objects["ordinary"]?.kind, .table)
                XCTAssertEqual(objects["partitioned"]?.isPartitioned, true)
                XCTAssertEqual(objects["child"]?.isPartition, true)
                XCTAssertEqual(objects["ordinary_view"]?.kind, .view)
                XCTAssertEqual(objects["populated"]?.kind, .materializedView)
                XCTAssertEqual(objects["populated"]?.isPopulated, true)
                XCTAssertEqual(objects["unpopulated"]?.isPopulated, false)
                XCTAssertEqual(page.database.name, source.profile.database)
                XCTAssertNil(page.nextCursor)
                XCTAssertTrue(page.objects.allSatisfy { $0.schema == schema && $0.hasSchemaUsage && $0.hasTableSelect })
                let all = try await service.page(source: source, password: password, query: CatalogQuery())
                XCTAssertFalse(all.objects.contains { $0.schema.hasPrefix("pg_") || $0.schema == "information_schema" })
                XCTAssertFalse(all.objects.contains { $0.name == "db3_catalog_excluded_temp" })
                let tables = try await service.page(source: source, password: password, query: CatalogQuery(search: schema, kind: .table))
                XCTAssertEqual(tables.objects.count, 3)
                XCTAssertTrue(tables.objects.allSatisfy { $0.kind == .table })
            } catch { await service.disconnect(); throw error }
            await service.disconnect()
        }
    }

    func testServerSearchFindsObjectsBeyondFirstPageAndLiteralCharacters() async throws {
        try await withFixture { setup, source, password, schema in
            try await run("""
                DO $fixture$ BEGIN
                    FOR i IN 1..510 LOOP
                        EXECUTE format('CREATE TABLE %I.%I (id integer)', '\(schema)', 'item' || lpad(i::text, 4, '0'));
                    END LOOP;
                END $fixture$
                """, on: setup)
            let odd = "z%_\\\".açãoMiXeD"
            for sql in [
                "CREATE TABLE \(schema).zz_table (id integer)",
                "CREATE VIEW \(schema).zz_view AS SELECT 1 AS id",
                "CREATE MATERIALIZED VIEW \(schema).zz_materialized AS SELECT 1 AS id",
                "CREATE TABLE \(schema).\(DatabaseObject.quoteIdentifier(odd)) (id integer)"
            ] { try await run(sql, on: setup) }
            let service = PostgresCatalogService()
            do {
                let first = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertEqual(first.objects.count, 500)
                let cursor = try XCTUnwrap(first.nextCursor)
                let second = try await service.page(source: source, password: password, query: CatalogQuery(search: schema, cursor: cursor))
                XCTAssertEqual(second.objects.count, 14)
                XCTAssertNil(second.nextCursor)
                XCTAssertEqual(Set((first.objects + second.objects).map(\.id)).count, 514)
                for (needle, kind) in [("zz_table", DatabaseObjectKind.table), ("zz_view", .view), ("zz_materialized", .materializedView)] {
                    let filtered = try await service.page(source: source, password: password, query: CatalogQuery(search: schema + "." + needle, kind: kind))
                    XCTAssertEqual(filtered.objects.map(\.name), [needle])
                }
                for needle in ["%", "_\\\"", "açãoMiXeD", ".ação", "MiXeD"] {
                    let filtered = try await service.page(source: source, password: password, query: CatalogQuery(search: needle))
                    XCTAssertTrue(filtered.objects.contains { $0.schema == schema && $0.name == odd }, "Literal search: \(needle)")
                    XCTAssertFalse(filtered.objects.contains { $0.schema == schema && $0.name == "zz_table" })
                }
                let missing = try await service.page(source: source, password: password, query: CatalogQuery(search: "absent" + schema))
                XCTAssertTrue(missing.objects.isEmpty)
                XCTAssertNil(missing.nextCursor)
            } catch { await service.disconnect(); throw error }
            await service.disconnect()
        }
    }

    func testSchemaFilterIsExactAndDiscoveryIncludesEmptySchemasIndependentlyOfFilters() async throws {
        try await withFixture { setup, source, password, schema in
            let special = schema + " Sales\".'%_\\--", empty = schema + "empty"
            let quotedSpecial = DatabaseObject.quoteIdentifier(special)
            let service = PostgresCatalogService()
            do {
                for sql in [
                    "CREATE SCHEMA \(quotedSpecial)",
                    "CREATE SCHEMA \(empty)",
                    "CREATE TABLE \(schema).same_name (id integer)",
                    "CREATE TABLE \(quotedSpecial).same_name (id integer)",
                    "CREATE VIEW \(quotedSpecial).only_view AS SELECT 1 AS id"
                ] { try await run(sql, on: setup) }
                let filtered = try await service.page(source: source, password: password,
                    query: CatalogQuery(search: "same_name", kind: .table, schema: special))
                XCTAssertEqual(filtered.objects.map(\.name), ["same_name"])
                XCTAssertEqual(filtered.objects.map(\.schema), [special])
                XCTAssertTrue(filtered.schemas.contains(schema))
                XCTAssertTrue(filtered.schemas.contains(special))
                XCTAssertTrue(filtered.schemas.contains(empty), "Discovery must include schemas with no tables or views.")
                XCTAssertFalse(filtered.schemasTruncated)
                XCTAssertFalse(filtered.schemas.contains { $0 == "information_schema" || $0.hasPrefix("pg_") })

                let absent = try await service.page(source: source, password: password,
                    query: CatalogQuery(search: "no_such_object", kind: .materializedView, schema: special))
                XCTAssertTrue(absent.objects.isEmpty)
                XCTAssertEqual(absent.schemas, filtered.schemas, "Schema choices must not depend on object search or kind.")
                let emptyPage = try await service.page(source: source, password: password, query: CatalogQuery(schema: empty))
                XCTAssertTrue(emptyPage.objects.isEmpty)
                XCTAssertEqual(emptyPage.schemas, filtered.schemas)

                for unmatched in [schema + " Sales", special.uppercased(), "%", "' OR TRUE --", "information_schema", "pg_catalog"] {
                    let page = try await service.page(source: source, password: password, query: CatalogQuery(schema: unmatched))
                    XCTAssertTrue(page.objects.isEmpty, "Schema filtering must match the exact identifier: \(unmatched)")
                }
                let all = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertEqual(Set(all.objects.map(\.schema)), [schema, special])
                await service.disconnect()
                try await run("DROP SCHEMA \(quotedSpecial) CASCADE", on: setup)
                try await run("DROP SCHEMA \(empty)", on: setup)
            } catch {
                await service.disconnect()
                try? await run("DROP SCHEMA IF EXISTS \(quotedSpecial) CASCADE", on: setup)
                try? await run("DROP SCHEMA IF EXISTS \(empty) CASCADE", on: setup)
                throw error
            }
        }
    }

    func testSchemaFilteredPagingOmitsRepeatedDiscoveryAndKeepsExactScope() async throws {
        try await withFixture { setup, source, password, schema in
            let sibling = schema + "sibling"
            let service = PostgresCatalogService()
            do {
                for sql in [
                    "CREATE SCHEMA \(sibling)",
                    "CREATE TABLE \(schema).a (id integer)",
                    "CREATE TABLE \(schema).b (id integer)",
                    "CREATE TABLE \(schema).c (id integer)",
                    "CREATE TABLE \(sibling).b (id integer)"
                ] { try await run(sql, on: setup) }
                let first = try await service.page(source: source, password: password,
                    query: CatalogQuery(schema: schema, limit: 2))
                XCTAssertEqual(first.objects.map(\.name), ["a", "b"])
                XCTAssertTrue(first.schemas.contains(sibling))
                let cursor = try XCTUnwrap(first.nextCursor)
                let second = try await service.page(source: source, password: password,
                    query: CatalogQuery(schema: schema, cursor: cursor, limit: 2))
                XCTAssertEqual(second.objects.map(\.name), ["c"])
                XCTAssertEqual(second.objects.map(\.schema), [schema])
                XCTAssertEqual(second.generation, first.generation)
                XCTAssertNil(second.nextCursor)
                XCTAssertTrue(second.schemas.isEmpty, "Append pages must not repeat schema discovery.")
                XCTAssertFalse(second.schemasTruncated)
                await service.disconnect()
                try await run("DROP SCHEMA \(sibling) CASCADE", on: setup)
            } catch {
                await service.disconnect()
                try? await run("DROP SCHEMA IF EXISTS \(sibling) CASCADE", on: setup)
                throw error
            }
        }
    }

    func testSchemaDiscoveryIsBoundedAndReportsTruncation() async throws {
        try await withFixture { setup, source, password, schema in
            let service = PostgresCatalogService()
            // Each batch is committed independently to keep fixture setup and
            // teardown below PostgreSQL's shared lock table limit.
            @MainActor func removeSchemas() async throws {
                for start in stride(from: 1, through: 5001, by: 250) {
                    let names = (start...min(start + 249, 5001)).map { schema + "_" + String(format: "%04d", $0) }
                    try await run("DROP SCHEMA IF EXISTS " + names.joined(separator: ", "), on: setup)
                }
            }
            do {
                for start in stride(from: 1, through: 5001, by: 250) {
                    try await run("""
                        DO $fixture$ BEGIN
                            FOR i IN \(start)..\(min(start + 249, 5001)) LOOP
                                EXECUTE format('CREATE SCHEMA %I', '\(schema)_' || lpad(i::text, 4, '0'));
                            END LOOP;
                        END $fixture$
                        """, on: setup)
                }
                let page = try await service.page(source: source, password: password,
                    query: CatalogQuery(search: "no_such_object", kind: .view, schema: schema))
                XCTAssertTrue(page.objects.isEmpty)
                XCTAssertEqual(page.schemas.count, 5000)
                XCTAssertEqual(Set(page.schemas).count, 5000)
                XCTAssertTrue(page.schemasTruncated)
                XCTAssertFalse(page.schemas.contains(schema + "_5001"))
                await service.disconnect()
                try await removeSchemas()
            } catch {
                await service.disconnect()
                try? await removeSchemas()
                throw error
            }
        }
    }

    func testColumnOnlyAndDeniedPrivilegesRemainVisible() async throws {
        try await withFixture { setup, source, password, schema in
            let role = schema + "role", hiddenSchema = schema + "hidden"
            try await run("CREATE ROLE \(role) LOGIN", on: setup)
            do {
                for sql in [
                    "CREATE SCHEMA \(hiddenSchema)",
                    "CREATE TABLE \(schema).whole_table (id integer, secret text)",
                    "CREATE TABLE \(schema).one_column (id integer, secret text)",
                    "CREATE TABLE \(schema).denied (id integer)",
                    "CREATE TABLE \(hiddenSchema).denied_schema (id integer)",
                    "GRANT USAGE ON SCHEMA \(schema) TO \(role)",
                    "GRANT SELECT ON \(schema).whole_table TO \(role)",
                    "GRANT SELECT(id) ON \(schema).one_column TO \(role)"
                ] { try await run(sql, on: setup) }
                var profile = source.profile; profile.username = role
                let restrictedSource = CatalogSource(profile: profile, revision: UUID())
                let service = PostgresCatalogService()
                do {
                    let page = try await service.page(source: restrictedSource, password: password, query: CatalogQuery(search: schema))
                    let objects = Dictionary(uniqueKeysWithValues: page.objects.map { ($0.name, $0) })
                    XCTAssertEqual(objects.count, 4)
                    XCTAssertEqual(objects["whole_table"]?.hasTableSelect, true)
                    XCTAssertEqual(objects["one_column"]?.hasTableSelect, false)
                    XCTAssertEqual(objects["one_column"]?.hasAnyColumnSelect, true)
                    XCTAssertEqual(objects["one_column"]?.hasSchemaUsage, true)
                    XCTAssertEqual(objects["denied"]?.hasTableSelect, false)
                    XCTAssertEqual(objects["denied"]?.hasAnyColumnSelect, false)
                    XCTAssertEqual(objects["denied_schema"]?.hasSchemaUsage, false)
                    try await run("REVOKE SELECT(id) ON \(schema).one_column FROM \(role)", on: setup)
                    let revoked = try await service.page(source: restrictedSource, password: password, query: CatalogQuery(search: schema + ".one_column"))
                    XCTAssertEqual(revoked.objects.first?.hasAnyColumnSelect, false)
                } catch { await service.disconnect(); throw error }
                await service.disconnect()
                try await run("DROP SCHEMA \(hiddenSchema) CASCADE", on: setup)
                try await run("DROP OWNED BY \(role)", on: setup)
                try await run("DROP ROLE \(role)", on: setup)
            } catch {
                try? await run("DROP SCHEMA \(hiddenSchema) CASCADE", on: setup)
                try? await run("DROP OWNED BY \(role)", on: setup)
                try? await run("DROP ROLE \(role)", on: setup)
                throw error
            }
        }
    }

    func testRenameKeepsIdentityButReconnectAndRevisionInvalidateIt() async throws {
        try await withFixture { setup, source, password, schema in
            try await run("CREATE TABLE \(schema).before_name (id integer)", on: setup)
            let service = PostgresCatalogService()
            do {
                let first = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                let original = try XCTUnwrap(first.objects.first)
                try await run("ALTER TABLE \(schema).before_name RENAME TO after_name", on: setup)
                let refreshed = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertEqual(refreshed.objects.first?.id, original.id)
                XCTAssertEqual(refreshed.objects.first?.name, "after_name")
                await service.disconnect()
                let reconnected = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertNotEqual(reconnected.objects.first?.id, original.id)
                let revised = try await service.page(source: CatalogSource(profile: source.profile, revision: UUID()), password: password, query: CatalogQuery(search: schema))
                XCTAssertNotEqual(revised.generation, reconnected.generation)
                try await run("DROP TABLE \(schema).after_name", on: setup)
                try await run("CREATE TABLE \(schema).after_name (id integer)", on: setup)
                let recreated = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertNotEqual(recreated.objects.first?.id.relationOID, original.id.relationOID)
            } catch { await service.disconnect(); throw error }
            await service.disconnect()
        }
    }

    func testDuplicateNamesAndQuotedSchemasRemainDistinctAndGeneratedSQLIsValid() async throws {
        try await withFixture { setup, source, password, schema in
            let secondSchema = schema + " Sales\"."
            let quotedSecond = DatabaseObject.quoteIdentifier(secondSchema)
            try await run("CREATE SCHEMA \(quotedSecond)", on: setup)
            let service = PostgresCatalogService()
            do {
                for sql in [
                    "CREATE TABLE \(schema).same_name (id integer)",
                    "CREATE TABLE \(quotedSecond).same_name (id integer)",
                    "CREATE TABLE \(quotedSecond).\"Order.Items\" (id integer)"
                ] { try await run(sql, on: setup) }
                let page = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                let duplicates = page.objects.filter { $0.name == "same_name" }
                XCTAssertEqual(duplicates.count, 2)
                XCTAssertEqual(Set(duplicates.map(\.id)).count, 2)
                XCTAssertEqual(Set(duplicates.map(\.schema)), [schema, secondSchema])
                let quoted = try XCTUnwrap(page.objects.first { $0.name == "Order.Items" })
                let executed = try await setup.execute(sql: quoted.selectSQL) { _ in }
                XCTAssertEqual(executed.rowCount, 0)
                let search = try await service.page(source: source, password: password, query: CatalogQuery(search: "Sales\"..Order.Items"))
                XCTAssertEqual(search.objects.map(\.id), [quoted.id])
                await service.disconnect()
                try await run("DROP SCHEMA \(quotedSecond) CASCADE", on: setup)
            } catch {
                await service.disconnect()
                try? await run("DROP SCHEMA \(quotedSecond) CASCADE", on: setup)
                throw error
            }
        }
    }

    func testLargeDisposableCatalogPublishesBoundedPagesAndReportsSearchTiming() async throws {
        try await withFixture { setup, source, password, schema in
            try await run("""
                DO $fixture$ BEGIN
                    FOR i IN 1..5500 LOOP
                        EXECUTE format('CREATE VIEW %I.%I AS SELECT 1 AS id', '\(schema)', 'view' || lpad(i::text, 5, '0'));
                    END LOOP;
                END $fixture$
                """, on: setup)
            let service = PostgresCatalogService()
            do {
                let firstStart = ContinuousClock.now
                let first = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                let firstDuration = firstStart.duration(to: .now)
                XCTAssertEqual(first.objects.count, 500)
                XCTAssertNotNil(first.nextCursor)
                let searchStart = ContinuousClock.now
                let found = try await service.page(source: source, password: password, query: CatalogQuery(search: schema + ".view05500"))
                let searchDuration = searchStart.duration(to: .now)
                XCTAssertEqual(found.objects.map(\.name), ["view05500"])
                let pageBytes = first.objects.reduce(0) { $0 + $1.byteCount }
                XCTAssertLessThan(pageBytes, 8 * 1024 * 1024)
                print("Disposable catalog measurement: 5,500 views; first 500 = \(firstDuration); targeted search = \(searchDuration); decoded page estimate = \(pageBytes) bytes. This local fixture is not a server benchmark.")
            } catch {
                await service.disconnect()
                try? await dropLargeFixtureViews(schema: schema, on: setup)
                throw error
            }
            await service.disconnect()
            try await dropLargeFixtureViews(schema: schema, on: setup)
        }
    }

    func testCatalogCancellationAndStatementDeadlineRecoverBeforeRetry() async throws {
        try await withFixture { setup, source, password, schema in
            try await run("CREATE TABLE \(schema).present (id integer)", on: setup)
            let service = PostgresCatalogService()
            do {
                let initial = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                try await run("BEGIN", on: setup)
                try await run("LOCK TABLE pg_catalog.pg_class IN ACCESS EXCLUSIVE MODE", on: setup)
                let blocked = Task { try await service.page(source: source, password: password, query: CatalogQuery(search: schema)) }
                try await Task.sleep(for: .milliseconds(100))
                let cancellationStart = ContinuousClock.now
                blocked.cancel()
                do { _ = try await blocked.value; XCTFail("Blocked catalog work must cancel.") } catch { }
                XCTAssertLessThan(cancellationStart.duration(to: .now), .seconds(2))
                try await run("ROLLBACK", on: setup)
                let recovered = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertEqual(recovered.objects.map(\.name), ["present"])
                XCTAssertEqual(recovered.generation, initial.generation)

                try await run("BEGIN", on: setup)
                try await run("LOCK TABLE pg_catalog.pg_class IN ACCESS EXCLUSIVE MODE", on: setup)
                let deadlineStart = ContinuousClock.now
                do {
                    _ = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                    XCTFail("The catalog deadline must cancel a blocked statement.")
                } catch let error as DatabaseError {
                    XCTAssertTrue(error.sqlState == "57014" || error.message.contains("timed out"))
                }
                XCTAssertLessThan(deadlineStart.duration(to: .now), .seconds(13))
                try await run("ROLLBACK", on: setup)
                let afterDeadline = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertEqual(afterDeadline.objects.map(\.name), ["present"])
            } catch {
                try? await run("ROLLBACK", on: setup)
                await service.disconnect()
                throw error
            }
            await service.disconnect()
        }
    }

    func testCatalogUsesCommittedStateWithoutChangingWorksheetTransactionsOrBusyQuery() async throws {
        try await withFixture { worksheet, source, password, schema in
            let service = PostgresCatalogService()
            var busy: Task<QuerySummary, any Error>?
            do {
                try await run("BEGIN", on: worksheet)
                try await run("CREATE TABLE \(schema).committed_after_transaction (id integer)", on: worksheet)
                try await run("CREATE TEMP TABLE \(schema)_temporary (id integer)", on: worksheet)
                let beforeCommit = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertTrue(beforeCommit.objects.isEmpty, "A separate catalog session must not expose worksheet-local or uncommitted relations.")
                let openTransaction = await worksheet.transactionState()
                XCTAssertEqual(openTransaction, .inTransaction)

                try await run("COMMIT", on: worksheet)
                let afterCommit = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertEqual(afterCommit.objects.map(\.name), ["committed_after_transaction"])
                let committedState = await worksheet.transactionState()
                XCTAssertEqual(committedState, .idle)

                try await run("BEGIN", on: worksheet)
                do { try await run("SELECT 1 / 0", on: worksheet); XCTFail("The worksheet transaction must fail.") }
                catch let error as DatabaseError { XCTAssertEqual(error.sqlState, "22012") }
                let failedBeforeBrowsing = await worksheet.transactionState()
                XCTAssertEqual(failedBeforeBrowsing, .failed)
                let whileFailed = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertEqual(whileFailed.objects.map(\.name), ["committed_after_transaction"])
                let failedAfterBrowsing = await worksheet.transactionState()
                XCTAssertEqual(failedAfterBrowsing, .failed, "Browsing must not roll back the worksheet's failed transaction.")
                try await run("ROLLBACK", on: worksheet)

                busy = Task { try await worksheet.execute(sql: "SELECT pg_sleep(30)") { _ in } }
                try await Task.sleep(for: .milliseconds(80))
                let beforeBusyBrowse = await worksheet.transactionState()
                XCTAssertEqual(beforeBusyBrowse, .unknown) // PQTRANS_ACTIVE while the independent query is running.
                let whileBusy = try await service.page(source: source, password: password, query: CatalogQuery(search: schema))
                XCTAssertEqual(whileBusy.objects.map(\.name), ["committed_after_transaction"])
                let afterBusyBrowse = await worksheet.transactionState()
                XCTAssertEqual(afterBusyBrowse, .unknown, "Browsing must leave the running worksheet command active.")
                busy?.cancel()
                do { _ = try await busy?.value; XCTFail("The worksheet stops only after its own explicit cancellation.") } catch { }
                busy = nil
                try await run("SELECT 1", on: worksheet)
            } catch {
                busy?.cancel()
                _ = try? await busy?.value
                try? await run("ROLLBACK", on: worksheet)
                await service.disconnect()
                throw error
            }
            await service.disconnect()
        }
    }

    func testConcurrentSourceChangesAdmitOnlyOneCatalogSession() async throws {
        try await withFixture { setup, source, password, schema in
            let role = schema + "owner"
            try await run("CREATE ROLE \(role) LOGIN", on: setup)
            var profile = source.profile; profile.username = role
            let service = PostgresCatalogService()
            var operations: [Task<CatalogPage, any Error>] = []
            do {
                for _ in 0..<16 {
                    let revised = CatalogSource(profile: profile, revision: UUID())
                    operations.append(Task { try await service.page(source: revised, password: password, query: CatalogQuery(search: schema)) })
                }
                var peak = 0
                for _ in 0..<60 {
                    let collector = CatalogTestRows()
                    _ = try await setup.execute(sql: "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE usename = $1", parameters: [role]) {
                        await collector.consume($0)
                    }
                    let rows = await collector.rows
                    let count = Int(rows.first?.first?.displayText ?? "-1") ?? -1
                    XCTAssertGreaterThanOrEqual(count, 0)
                    peak = max(peak, count)
                    XCTAssertLessThanOrEqual(count, 1, "Connecting/closing owners must also obey the one-session budget.")
                    try await Task.sleep(for: .milliseconds(2))
                }
                for operation in operations { _ = try await operation.value }
                XCTAssertEqual(peak, 1)
                await service.disconnect()
                try await run("DROP ROLE \(role)", on: setup)
            } catch {
                for operation in operations { operation.cancel() }
                await service.disconnect()
                try? await run("DROP ROLE \(role)", on: setup)
                throw error
            }
        }
    }
}

private actor CatalogTestRows {
    private(set) var rows: [DatabaseRow] = []
    func consume(_ event: QueryEvent) { if case .rows(let batch) = event { rows.append(contentsOf: batch.rows) } }
}
