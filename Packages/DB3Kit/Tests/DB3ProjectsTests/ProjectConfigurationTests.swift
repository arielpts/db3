import Foundation
import XCTest
import DB3Core
@testable import DB3Projects

final class ProjectConfigurationTests: XCTestCase, @unchecked Sendable {
    func testLiteralQuotingEmptyValuesAndAllowedPreviousInterpolation() throws {
        let document = try ProjectDotEnvParser.parse(#"""
        export DB_HOST = 'localhost'
        DB_PASSWORD=
        DB_NAME="example # database" # trailing
        DB_USER=example#user
        DB_COPY=${DB_HOST}
        DB_LITERAL='${DB_HOST}'
        DB_ESCAPED="\$DB_HOST"
        DB_TAB="a\tb"
        DB_COMMENT=value # hidden
        """#, allowedVariables: ["DB_HOST"])
        XCTAssertEqual(document.entries["DB_HOST"]?.value, .value("localhost"))
        XCTAssertEqual(document.entries["DB_PASSWORD"]?.value, .empty)
        XCTAssertNil(document.entries["MISSING"])
        XCTAssertEqual(document.entries["DB_NAME"]?.value, .value("example # database"))
        XCTAssertEqual(document.entries["DB_USER"]?.value, .value("example#user"))
        XCTAssertEqual(document.entries["DB_COPY"]?.value, .value("localhost"))
        XCTAssertEqual(document.entries["DB_LITERAL"]?.value, .value("${DB_HOST}"))
        XCTAssertEqual(document.entries["DB_ESCAPED"]?.value, .value("$DB_HOST"))
        XCTAssertEqual(document.entries["DB_TAB"]?.value, .value("a\tb"))
        XCTAssertEqual(document.entries["DB_COMMENT"]?.value, .value("value"))
        XCTAssertTrue(document.diagnostics.isEmpty)
    }

    func testNoInheritedEnvironmentCommandExecutionOrForwardReferenceResolution() throws {
        let document = try ProjectDotEnvParser.parse(#"""
        DB_HOME=${HOME}
        DB_COMMAND=$(printf synthetic-secret)
        DB_FIRST=${DB_SECOND}
        DB_SECOND=${DB_FIRST}
        DB_BACKTICKS='`printf synthetic-secret`'
        DB_COMPLEX=${DB_PASSWORD:-synthetic-secret}
        DB_BROKEN="synthetic-secret
        """#, allowedVariables: ["HOME", "DB_FIRST", "DB_SECOND"])
        for key in ["DB_HOME", "DB_COMMAND", "DB_FIRST", "DB_SECOND", "DB_COMPLEX", "DB_BROKEN"] {
            guard case .unresolved = document.entries[key]?.value else { return XCTFail("Expected unresolved \(key)") }
        }
        XCTAssertEqual(document.entries["DB_BACKTICKS"]?.value, .value("`printf synthetic-secret`"))
        XCTAssertFalse(document.diagnostics.map(\.message).joined().contains("synthetic-secret"))
        XCTAssertFalse(String(describing: document.entries["DB_COMPLEX"]?.value).contains("synthetic-secret"))
    }

    func testParserBoundsDuplicateDiagnosticsAndCancellation() async throws {
        XCTAssertThrowsError(try ProjectDotEnvParser.parse(String(repeating: "x", count: ProjectDotEnvParser.maximumBytes + 1)))
        let many = try ProjectDotEnvParser.parse((0..<4100).map { "KEY_\($0)=value" }.joined(separator: "\n"))
        XCTAssertEqual(many.entries.count, 4096)
        XCTAssertTrue(many.diagnostics.contains { $0.message.contains("limit") })
        let duplicate = try ProjectDotEnvParser.parse("DB_PASSWORD=synthetic-one\nDB_PASSWORD=synthetic-two")
        XCTAssertEqual(duplicate.entries["DB_PASSWORD"]?.value, .value("synthetic-two"))
        XCTAssertFalse(duplicate.diagnostics.map(\.message).joined().contains("synthetic-"))
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ProjectDotEnvParser.parse("DB_HOST=localhost")
        }
        do { _ = try await task.value; XCTFail("Canceled parser continued") }
        catch is CancellationError { }
    }

    func testDiscoveryKeepsGroupsAndTLSReviewSeparate() async throws {
        let folder = try ProjectConfigTestFolder()
        try folder.write("odoo_repositories.json", "{}")
        try folder.write(".env", """
        DB_HOST=localhost
        DB_NAME=example_dev
        DB_USER=example_role
        DB_PASSWORD=
        PRODUCTION_DB_HOST=production.example.invalid
        PRODUCTION_DB_NAME=example_prod
        PRODUCTION_DB_USER=production_role
        PRODUCTION_DB_PASSWORD=synthetic-production-password
        PRODUCTION_DB_SSLMODE=require
        DATALAKE_DATABASE_URL='postgresql://example:synthetic%40password@analytics.example.invalid/example'
        ODOO_BASE_URL=https://odoo.example.invalid
        ODOO_API_KEY=synthetic-application-token
        """)
        let snapshot = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        XCTAssertEqual(snapshot.candidates.count, 4)
        let development = try XCTUnwrap(snapshot.candidates.first { $0.sourceGroup == "DB_" })
        let production = try XCTUnwrap(snapshot.candidates.first { $0.sourceGroup == "PRODUCTION_DB_" })
        let lake = try XCTUnwrap(snapshot.candidates.first { $0.sourceGroup == "DATALAKE_DATABASE_URL" })
        let application = try XCTUnwrap(snapshot.candidates.first { $0.kind == .odooEvidence })
        XCTAssertEqual(development.environment, .development)
        XCTAssertEqual(development.password, .empty)
        XCTAssertEqual(development.port, .missing)
        XCTAssertEqual(production.environment, .production)
        XCTAssertEqual(production.database, .value("example_prod"))
        XCTAssertEqual(production.tls, .specified(.require))
        XCTAssertEqual(production.reviewProfile().tls, .verifyFull)
        XCTAssertEqual(lake.environment, .unknown)
        XCTAssertEqual(lake.password, .value("synthetic@password"))
        XCTAssertEqual(lake.tls, .missing)
        XCTAssertTrue(lake.reviewErrors.contains { $0.contains("TLS") })
        XCTAssertEqual(application.username, .missing)
        XCTAssertEqual(application.database, .value("example_dev"))
        XCTAssertTrue(application.reviewErrors.contains { $0.contains("task 08") })
    }

    func testGenericLocalhostDoesNotInferDevelopmentOrInheritDefaultUser() async throws {
        let folder = try ProjectConfigTestFolder()
        try folder.write(".env", "DB_HOST=localhost\nDB_NAME=example\nDATABASE_URL='postgresql://localhost/example'\nDEV_DATABASE_URL='postgres://example@localhost/example?sslmode=verify-full'")
        let snapshot = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        let grouped = try XCTUnwrap(snapshot.candidates.first { $0.sourceGroup == "DB_" })
        let url = try XCTUnwrap(snapshot.candidates.first { $0.sourceGroup == "DATABASE_URL" })
        let explicit = try XCTUnwrap(snapshot.candidates.first { $0.sourceGroup == "DEV_DATABASE_URL" })
        XCTAssertEqual(grouped.environment, .unknown)
        XCTAssertEqual(url.username, .missing)
        XCTAssertEqual(url.reviewProfile().username, "")
        XCTAssertTrue(url.hasUnresolvedRequirements)
        XCTAssertEqual(explicit.environment, .development)
        XCTAssertFalse(explicit.tls.requiresReview)
    }

    func testCredentialChangesAffectOnlyEphemeralSecretRevision() async throws {
        let folder = try ProjectConfigTestFolder()
        func source(_ password: String) -> String { "DB_HOST=localhost\nDB_NAME=example\nDB_USER=example\nDB_PASSWORD=\(password)" }
        try folder.write(".env", source("synthetic-one"))
        let initial = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        try folder.write(".env", source("synthetic-two"))
        let changed = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        XCTAssertEqual(initial.candidates[0].id, changed.candidates[0].id)
        XCTAssertEqual(initial.candidates[0].nonsecretFingerprint, changed.candidates[0].nonsecretFingerprint)
        XCTAssertNotEqual(initial.candidates[0].secretRevision, changed.candidates[0].secretRevision)
        XCTAssertNotEqual(initial.revision, changed.revision)
        XCTAssertEqual(changed.candidates[0].secretRevision.count, 64)
        XCTAssertFalse(changed.candidates[0].nonsecretFingerprint.contains("synthetic"))
    }

    func testUnsupportedURLsRemainUnresolvedAndNeverExposeValuesInDiagnostics() async throws {
        let folder = try ProjectConfigTestFolder()
        try folder.write(".env", "DATABASE_URL='postgresql://example:synthetic-secret@localhost/example?options=unsafe'\nDB_PORT=70000\nDB_SSLMODE=prefer")
        let snapshot = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        let url = try XCTUnwrap(snapshot.candidates.first { $0.sourceGroup == "DATABASE_URL" })
        let group = try XCTUnwrap(snapshot.candidates.first { $0.sourceGroup == "DB_" })
        XCTAssertTrue(url.hasUnresolvedRequirements)
        XCTAssertEqual(url.password, .missing)
        XCTAssertFalse(snapshot.diagnostics.map(\.message).joined().contains("synthetic-secret"))
        XCTAssertFalse(group.portIsValid)
        XCTAssertEqual(group.tls, .unsupported("prefer"))
        XCTAssertEqual(group.reviewProfile().tls, .verifyFull)
    }

    func testUnresolvedSecretChangesStillInvalidateEphemeralRevision() async throws {
        let folder = try ProjectConfigTestFolder()
        try folder.write(".env", "DB_PASSWORD=${UNAVAILABLE_FIRST}\nDATABASE_URL='invalid://synthetic-one'")
        let first = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        try folder.write(".env", "DB_PASSWORD=${UNAVAILABLE_SECOND}\nDATABASE_URL='invalid://synthetic-two'")
        let second = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        XCTAssertEqual(first.candidates.map(\.nonsecretFingerprint), second.candidates.map(\.nonsecretFingerprint))
        XCTAssertNotEqual(first.candidates[0].secretRevision, second.candidates[0].secretRevision)
        XCTAssertNotEqual(first.candidates[1].secretRevision, second.candidates[1].secretRevision)
        XCTAssertNotEqual(first.revision, second.revision)
        XCTAssertFalse(second.diagnostics.map(\.message).joined().contains("synthetic-two"))
    }

    func testUnsafeConfigurationParentIsNotFollowedAndCoverageIsPartial() async throws {
        let folder = try ProjectConfigTestFolder(), outside = try ProjectConfigTestFolder()
        try outside.write("odoo-dev.conf", "db_host=${OUTSIDE}")
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent("config"), withDestinationURL: outside.url)
        XCTAssertThrowsError(try ProjectFileIO.readIfPresent(folder.url.appendingPathComponent("config/odoo-dev.conf"), maximumBytes: 1024))
        let snapshot = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        XCTAssertFalse(snapshot.complete)
        XCTAssertTrue(snapshot.evidence.isEmpty)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.source.relativePath == "config" })
    }

    func testNoEnvStillInspectsEvidenceAndSymlinkReadsFailClosed() async throws {
        let folder = try ProjectConfigTestFolder()
        try folder.write("Makefile", "run:\n\tPGSSLMODE=prefer tool\nremote:\n\tPGSSLMODE=require tool")
        try folder.write("config/odoo-dev.conf", "db_host=${DB_HOST}")
        let snapshot = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        XCTAssertEqual(snapshot.evidence.filter { $0.kind == .tlsSetting }.count, 2)
        XCTAssertEqual(snapshot.evidence.filter { $0.kind == .odooPlaceholderConfiguration }.count, 1)
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent(".env"), withDestinationURL: folder.url.appendingPathComponent("Makefile"))
        let unsafe = try await ProjectConfigurationDiscovery.discover(root: folder.url)
        XCTAssertFalse(unsafe.complete)
        XCTAssertTrue(unsafe.candidates.isEmpty)
    }
}

final class ProjectConfigTestFolder: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("db3-project-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    func write(_ path: String, _ text: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
