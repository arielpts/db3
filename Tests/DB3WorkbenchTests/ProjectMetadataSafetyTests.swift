import Foundation
import XCTest
import DB3Core
import DB3Projects
@testable import DB3Workbench

@MainActor
final class ProjectMetadataSafetyTests: XCTestCase {
    private let relationOID: UInt32 = 73
    private var columns: [EditableColumn] {
        [.init(index: 0, attributeNumber: 1, name: "state", typeOID: 25, typeSQL: "pg_catalog.text", nullable: true, kind: .text)]
    }
    private func provenance(_ revision: String = "a") -> ProjectFactProvenance {
        .init(relativePath: "src/synthetic/models/item.py", range: .init(startLine: 2, endLine: 4),
            sourceDigest: revision, snapshotGeneration: UUID())
    }
    private func field(computed: Bool = false, choices: [ProjectValueChoice]? = nil, revision: String = "a") -> ProjectFieldMetadata {
        .init(name: "state", declaredType: "Selection", stored: true, computed: computed,
            choices: choices ?? [.init(key: "draft", label: "Draft", provenance: provenance(revision))],
            choicesResolution: .resolved, provenance: provenance(revision))
    }
    private func snapshot(fields: [ProjectFieldMetadata], resolution: ProjectFactResolution = .resolved,
                          revision: String = "a") -> ProjectInspectionSnapshot {
        let model = ProjectModelMetadata(name: "synthetic.item", kind: .regular, tableName: "synthetic_item",
            namespace: "synthetic", definingModule: "synthetic", fields: fields, provenance: [provenance(revision)], resolution: resolution)
        return ProjectInspectionSnapshot(generation: UUID(), rootDigest: revision,
            detection: .init(adapterID: "odoo", adapterVersion: "1", evidence: [], resolution: .resolved),
            roots: [], models: [model], diagnostics: [], completeness: .complete,
            sourceFileCount: 1, parsedFileCount: 1, metadataBytes: 512, elapsed: 0)
    }
    private func prepare(_ provider: ProjectMetadataProvider) async {
        await provider.prepare(databaseOID: 11, schemaOID: 22, relationOID: relationOID,
            schema: "public", table: "synthetic_item", columns: columns)
    }

    func testRemovedComputedFieldRetainsUnresolvedCautionForPhysicalColumn() async throws {
        let provider = ProjectMetadataProvider(schema: "public", databaseOID: 11)
        await provider.update(snapshot(fields: [field(computed: true)])); await prepare(provider)
        let original = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        XCTAssertEqual(original?.classification, .storedComputed)
        await provider.update(snapshot(fields: [], revision: "removed")); await prepare(provider)
        let retained = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        XCTAssertEqual(retained?.classification, .unresolved)
        XCTAssertEqual(retained?.modelField, "synthetic.item.state")
        XCTAssertNotEqual(retained?.revision, original?.revision)
        let choices = await provider.choices(relationOID: relationOID, attributeNumber: 1)
        XCTAssertFalse(choices?.isResolved ?? true)
        let physical = EditableColumn(index: 0, attributeNumber: 1, name: "state", typeOID: 25,
            typeSQL: "pg_catalog.text", nullable: true, kind: .text, applicationMetadata: retained)
        XCTAssertNotNil(physical.effectiveReadOnlyReason)
    }

    func testDuplicateFieldDeclarationsRemainUnresolvedRatherThanSelectingOne() async throws {
        let provider = ProjectMetadataProvider(schema: "public")
        await provider.update(snapshot(fields: [field(), field(computed: true)])); await prepare(provider)
        let metadata = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        XCTAssertEqual(metadata?.classification, .unresolved)
        let choices = await provider.choices(relationOID: relationOID, attributeNumber: 1)
        XCTAssertFalse(choices?.isResolved ?? true); XCTAssertTrue(choices?.choices.isEmpty ?? false)
    }

    func testDuplicateAndOversizedVocabularyHaveHonestTypedFallbackStatus() async throws {
        let duplicate = [ProjectValueChoice(key: "draft", label: "First", provenance: provenance()),
                         ProjectValueChoice(key: "draft", label: "Conflicting", provenance: provenance())]
        let oversized = [ProjectValueChoice(key: "draft", label: String(repeating: "x", count: ValueChoiceSet.maximumBytes), provenance: provenance())]
        for vocabulary in [duplicate, oversized] {
            let provider = ProjectMetadataProvider(schema: "public")
            await provider.update(snapshot(fields: [field(choices: vocabulary)])); await prepare(provider)
            let maybeChoices = await provider.choices(relationOID: relationOID, attributeNumber: 1)
            let choices = try XCTUnwrap(maybeChoices)
            XCTAssertFalse(choices.isResolved); XCTAssertTrue(choices.choices.isEmpty)
            XCTAssertTrue(choices.statusText.contains("invalid keys") || choices.statusText.contains("limit"))
            XCTAssertLessThan(choices.byteCount, 4_096)
            let metadata = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
            XCTAssertEqual(metadata?.classification, .ordinary, "Choice parsing alone must not invent computed-field restrictions.")
        }
    }

    func testSourceUpdateKeepsCapturedMetadataButRejectsItsMutationFence() async throws {
        let provider = ProjectMetadataProvider(schema: "public")
        await provider.update(snapshot(fields: [field(computed: true)])); await prepare(provider)
        let metadata = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        let choices = await provider.choices(relationOID: relationOID, attributeNumber: 1)
        try await provider.validatePreparedMetadata(relationOID: relationOID)
        await provider.update(snapshot(fields: [field(computed: true, revision: "next")], revision: "next"))
        let capturedMetadata = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        let capturedChoices = await provider.choices(relationOID: relationOID, attributeNumber: 1)
        XCTAssertEqual(capturedMetadata, metadata); XCTAssertEqual(capturedChoices, choices)
        do { try await provider.validatePreparedMetadata(relationOID: relationOID); XCTFail("An in-flight source update must invalidate Apply") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        await prepare(provider)
        try await provider.validatePreparedMetadata(relationOID: relationOID)
        let refreshed = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        XCTAssertNotEqual(refreshed?.revision, metadata?.revision)
        await provider.suspend()
        do { try await provider.validatePreparedMetadata(relationOID: relationOID); XCTFail("Suspension must invalidate Apply") } catch {}
    }

    func testNewComputedRestrictionInvalidatesPreviouslyUnmappedPreparedPass() async throws {
        let provider = ProjectMetadataProvider(schema: "public")
        await provider.update(snapshot(fields: [])); await prepare(provider)
        let before = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        XCTAssertNil(before)
        await provider.update(snapshot(fields: [field(computed: true, revision: "new-computed")], revision: "new-computed"))
        do { try await provider.validatePreparedMetadata(relationOID: relationOID); XCTFail("New source restrictions must invalidate an earlier pass even when no fields were initially mapped") } catch {}
    }

    func testKnownConflictingModelProvidesUnresolvedCautionAtFirstBinding() async throws {
        let provider = ProjectMetadataProvider(schema: "public")
        await provider.update(snapshot(fields: [field(computed: true)], resolution: .conflicting)); await prepare(provider)
        let metadata = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        XCTAssertEqual(metadata?.classification, .unresolved, "Known ambiguous source columns must not become ordinary direct-SQL fields by losing their source caution.")
    }

    func testCanonicallyEquivalentSchemaCannotReactivateCachedSourceBinding() async throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let provider = ProjectMetadataProvider(schema: composed)
        await provider.update(snapshot(fields: [field(computed: true)]))
        await provider.prepare(databaseOID: 11, schemaOID: 22, relationOID: relationOID,
            schema: composed, table: "synthetic_item", columns: columns)
        let verified = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        XCTAssertEqual(verified?.classification, .storedComputed)
        await provider.prepare(databaseOID: 11, schemaOID: 23, relationOID: relationOID,
            schema: decomposed, table: "synthetic_item", columns: columns)
        let mismatched = await provider.metadata(relationOID: relationOID, attributeNumber: 1)
        XCTAssertEqual(mismatched?.classification, .unresolved, "Swift-equivalent names are separate PostgreSQL schemas and must not share active source bindings.")
    }
}
