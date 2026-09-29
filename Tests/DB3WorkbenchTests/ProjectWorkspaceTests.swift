import Foundation
import XCTest
import DB3Core
import DB3Projects
@testable import DB3Workbench

@MainActor
final class ProjectWorkspaceTests: XCTestCase {
    private func fixture() throws -> (URL, ProjectWorkspaceModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("db3-project-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let privateFolder = root.appendingPathComponent("private")
        return (root, ProjectWorkspaceModel(privateStore: ProjectPrivateStore(directory: privateFolder)))
    }
    private func settled(_ project: ProjectWorkspaceModel) async throws {
        for _ in 0..<500 {
            if project.snapshot != nil && project.status != .inspecting && !project.savingSettings { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Project inspection did not settle")
    }
    func testOpeningDoesNotCreatePortableSettingsAndExplicitBindingScopesOverrides() async throws {
        let (root, project) = try fixture()
        do {
            await project.open(root); try await settled(project)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".db3/project.json").path))
            let profile = ConnectionProfile(name: "Synthetic", host: "synthetic.invalid", database: "test", username: "reader")
            XCTAssertNil(project.binding(for: profile))
            await project.bind(profile: profile, key: "local-app", schema: "public", candidateID: nil)
            try await settled(project)
            XCTAssertNotNil(project.binding(for: profile))
            var different = profile; different.database = "another"
            XCTAssertNil(project.binding(for: different))
            let source = CatalogSource(profile: profile, revision: UUID())
            let object = DatabaseObject(id: .init(source: source, databaseOID: 1, relationOID: 3, generation: UUID()),
                schemaOID: 2, schema: "public", name: "synthetic_item", kind: .table, identityToken: "10")
            project.observeObjects([object])
            await project.assign(object, namespace: "sales"); try await settled(project)
            XCTAssertEqual(project.namespace(for: object), "sales")
            project.selectedNamespace = "sales"
            let filter = project.catalogFilter(for: profile)
            XCTAssertEqual(filter.included, [.init(schema: "public", relation: "synthetic_item", oid: 3, token: "10")])
            let recreated = DatabaseObject(id: .init(source: source, databaseOID: 1, relationOID: 4, generation: UUID()),
                schemaOID: 2, schema: "public", name: "synthetic_item", kind: .table, identityToken: "11")
            XCTAssertEqual(project.namespace(for: recreated), "unclassified")
            let json = try String(contentsOf: root.appendingPathComponent(".db3/project.json"), encoding: .utf8)
            XCTAssertFalse(json.contains(profile.id.uuidString)); XCTAssertFalse(json.contains(profile.host))
            XCTAssertFalse(json.contains("identityToken")); XCTAssertTrue(json.contains("sales"))
            await project.shutdown(); try FileManager.default.removeItem(at: root)
        } catch { await project.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
    func testWorkspaceReopenRestartsInspectionAndPreservesProjectIdentity() async throws {
        let (root, project) = try fixture()
        do {
            await project.open(root); try await settled(project)
            let identity = try XCTUnwrap(project.recent?.id)
            let firstRevision = project.metadataRevision
            await project.shutdown()
            try "DEV_DB_HOST=synthetic.invalid\nDEV_DB_NAME=sample\nDEV_DB_USER=reader\nDEV_DB_PASSWORD=\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            await project.loadRecents(); try await settled(project)
            XCTAssertEqual(project.recent?.id, identity)
            XCTAssertNotEqual(project.metadataRevision, firstRevision)
            XCTAssertEqual(project.configuration?.candidates.count, 1)
            await project.shutdown(); try FileManager.default.removeItem(at: root)
        } catch { await project.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }

    func testCandidateAcceptedFromOldReviewCannotBindChangedConfiguration() async throws {
        let (root, project) = try fixture()
        do {
            let file = root.appendingPathComponent(".env")
            try "DEV_DB_HOST=synthetic.invalid\nDEV_DB_NAME=sample\nDEV_DB_USER=reader\nDEV_DB_PASSWORD=before\n".write(to: file, atomically: true, encoding: .utf8)
            await project.open(root); try await settled(project)
            let candidate = try XCTUnwrap(project.configuration?.candidates.first)
            let review = project.captureReview(candidate)
            try "DEV_DB_HOST=synthetic.invalid\nDEV_DB_NAME=sample\nDEV_DB_USER=reader\nDEV_DB_PASSWORD=after\n".write(to: file, atomically: true, encoding: .utf8)
            project.refresh(force: true)
            try await settled(project)
            let accepted = await project.bind(profile: candidate.reviewProfile(), key: "local-app", schema: "public", candidateID: candidate.id, expectedReview: review)
            XCTAssertFalse(accepted)
            XCTAssertTrue(project.bindings.isEmpty)
            XCTAssertNotNil(project.error)
            await project.shutdown(); try FileManager.default.removeItem(at: root)
        } catch { await project.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }

    func testConfigurationChangeRequiresReviewWithoutChangingSavedProfile() async throws {
        let (root, project) = try fixture()
        do {
            let file = root.appendingPathComponent(".env")
            try "DEV_DB_HOST=synthetic.invalid\nDEV_DB_NAME=sample\nDEV_DB_USER=reader\nDEV_DB_PASSWORD=first\n".write(to: file, atomically: true, encoding: .utf8)
            await project.open(root); try await settled(project)
            let candidate = try XCTUnwrap(project.configuration?.candidates.first)
            let profile = candidate.reviewProfile()
            await project.bind(profile: profile, key: "local-app", schema: "public", candidateID: candidate.id)
            try await settled(project)
            XCTAssertNil(project.policyRestriction(for: profile))
            try "DEV_DB_HOST=synthetic.invalid\nDEV_DB_NAME=sample\nDEV_DB_USER=reader\nDEV_DB_PASSWORD=second\n".write(to: file, atomically: true, encoding: .utf8)
            project.refresh(force: true)
            for _ in 0..<500 {
                if project.reviewRequired.contains("local-app") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(project.reviewRequired.contains("local-app"))
            XCTAssertEqual(project.policyRestriction(for: profile), .unknown)
            XCTAssertNil(project.binding(for: profile))
            XCTAssertEqual(profile.environment, .development)
            XCTAssertFalse(project.changedCandidates["local-app"]?.contains("second") == true)
            await project.shutdown(); try FileManager.default.removeItem(at: root)
        } catch { await project.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }
}

@MainActor
final class ProjectMetadataProviderTests: XCTestCase {
    private func snapshot(label: String = "Draft", computed: Bool = false, revision: String = "a") -> ProjectInspectionSnapshot {
        let generation = UUID()
        let provenance = ProjectFactProvenance(relativePath: "src/sample/models/item.py", range: .init(startLine: 1, endLine: 3), sourceDigest: revision, snapshotGeneration: generation)
        let choice = ProjectValueChoice(key: "draft", label: label, provenance: provenance)
        let field = ProjectFieldMetadata(name: "state", declaredType: "Selection", stored: true, computed: computed,
            choices: [choice], choicesResolution: .resolved, provenance: provenance)
        let model = ProjectModelMetadata(name: "sample.item", kind: .regular, tableName: "sample_item", namespace: "sample", definingModule: "sample", fields: [field], provenance: [provenance])
        return ProjectInspectionSnapshot(generation: generation, rootDigest: revision,
            detection: .init(adapterID: "odoo", adapterVersion: "1", evidence: [], resolution: .resolved), roots: [], models: [model], diagnostics: [], completeness: .complete,
            sourceFileCount: 1, parsedFileCount: 1, metadataBytes: 100, elapsed: 0)
    }
    private var columns: [EditableColumn] { [.init(index: 0, attributeNumber: 1, name: "state", typeOID: 25, typeSQL: "text", nullable: true, kind: .text)] }
    func testChoicesNeedVerifiedSchemaTableColumnAndDatabaseIdentity() async throws {
        let provider = ProjectMetadataProvider(schema: "public", databaseOID: 1)
        await provider.update(snapshot())
        let unverifiedChoices = await provider.choices(relationOID: 3, attributeNumber: 1)
        XCTAssertNil(unverifiedChoices)
        await provider.prepare(databaseOID: 1, schemaOID: 2, relationOID: 3, schema: "other", table: "sample_item", columns: columns)
        let unmatchedMetadata = await provider.metadata(relationOID: 3, attributeNumber: 1)
        XCTAssertNil(unmatchedMetadata)
        await provider.prepare(databaseOID: 1, schemaOID: 2, relationOID: 3, schema: "public", table: "sample_item", columns: columns)
        let choices = await provider.choices(relationOID: 3, attributeNumber: 1)
        XCTAssertEqual(choices?.choices.first?.key, "draft")
        await provider.prepare(databaseOID: 8, schemaOID: 2, relationOID: 3, schema: "public", table: "sample_item", columns: columns)
        let stale = await provider.metadata(relationOID: 3, attributeNumber: 1)
        XCTAssertEqual(stale?.classification, .unresolved)
    }
    func testCapturedDescribeStaysStableThenRefreshRequiresNewComputedAcknowledgement() async throws {
        let provider = ProjectMetadataProvider(schema: "public")
        await provider.update(snapshot(computed: true))
        await provider.prepare(databaseOID: 1, schemaOID: 2, relationOID: 3, schema: "public", table: "sample_item", columns: columns)
        let first = await provider.metadata(relationOID: 3, attributeNumber: 1)
        XCTAssertEqual(first?.classification, .storedComputed)
        await provider.update(snapshot(label: "Changed", computed: true, revision: "b"))
        let captured = await provider.metadata(relationOID: 3, attributeNumber: 1)
        XCTAssertEqual(first, captured)
        await provider.prepare(databaseOID: 1, schemaOID: 2, relationOID: 3, schema: "public", table: "sample_item", columns: columns)
        let changed = await provider.metadata(relationOID: 3, attributeNumber: 1)
        XCTAssertNotEqual(first?.revision, changed?.revision)
        await provider.suspend()
        await provider.prepare(databaseOID: 1, schemaOID: 2, relationOID: 3, schema: "public", table: "sample_item", columns: columns)
        let unresolved = await provider.metadata(relationOID: 3, attributeNumber: 1)
        XCTAssertEqual(unresolved?.classification, .unresolved)
    }
    func testIncompatiblePhysicalTypeCannotAuthorizeSourceChoiceEditing() async throws {
        let provider = ProjectMetadataProvider(schema: "public")
        await provider.update(snapshot())
        let integer = EditableColumn(index: 0, attributeNumber: 1, name: "state", typeOID: 23, typeSQL: "integer", nullable: false, kind: .integer)
        await provider.prepare(databaseOID: 1, schemaOID: 2, relationOID: 3, schema: "public", table: "sample_item", columns: [integer])
        let metadata = await provider.metadata(relationOID: 3, attributeNumber: 1)
        XCTAssertEqual(metadata?.classification, .unresolved)
        let choices = await provider.choices(relationOID: 3, attributeNumber: 1)
        XCTAssertNil(choices)
    }
}
