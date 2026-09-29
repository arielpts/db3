import Foundation
import XCTest
import DB3Core
import DB3Projects
@testable import DB3Workbench

@MainActor
final class ProjectBindingRecoveryTests: XCTestCase {
    private func settled(_ project: ProjectWorkspaceModel, until condition: () -> Bool = { true }) async throws {
        for _ in 0..<500 {
            if project.configuration != nil, project.status != .inspecting, !project.savingSettings, condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Project refresh did not reach the expected state")
    }
    private func withFixture(_ action: (URL, ProjectPrivateStore, ProjectWorkspaceModel) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("db3-binding-recovery-" + UUID().uuidString)
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectPrivateStore(directory: base.appendingPathComponent("private"))
        let project = ProjectWorkspaceModel(privateStore: store)
        do { try await action(root, store, project) }
        catch { await project.shutdown(); try? FileManager.default.removeItem(at: base); throw error }
        await project.shutdown()
        try FileManager.default.removeItem(at: base)
    }
    private func environment(_ password: String) -> String {
        "DEV_DB_HOST=synthetic.invalid\nDEV_DB_NAME=example\nDEV_DB_USER=example\nDEV_DB_PASSWORD=\(password)\n"
    }

    func testRestoredBindingStartsMemoryBaselineThenDetectsCredentialOnlyRefresh() async throws {
        try await withFixture { root, store, project in
            let env = root.appendingPathComponent(".env")
            try environment("synthetic-first").write(to: env, atomically: true, encoding: .utf8)
            await project.open(root); try await settled(project)
            let candidate = try XCTUnwrap(project.configuration?.candidates.first)
            let profile = candidate.reviewProfile()
            await project.bind(profile: profile, key: "local-app", schema: "public", candidateID: candidate.id)
            try await settled(project)
            await project.shutdown()
            let restored = ProjectWorkspaceModel(privateStore: store)
            do {
                await restored.loadRecents(); try await settled(restored)
                XCTAssertNotNil(restored.binding(for: profile))
                XCTAssertFalse(restored.reviewRequired.contains("local-app"))
                try environment("synthetic-second").write(to: env, atomically: true, encoding: .utf8)
                restored.refresh(force: true)
                try await settled(restored, until: { restored.reviewRequired.contains("local-app") })
                XCTAssertNil(restored.binding(for: profile))
                XCTAssertEqual(restored.policyRestriction(for: profile), .unknown)
                XCTAssertEqual(profile.environment, .development)
                XCTAssertFalse(restored.changedCandidates.values.joined().contains("synthetic-second"))
            } catch { await restored.shutdown(); throw error }
            await restored.shutdown()
        }
    }

    func testDeletingPortableBindingInvalidatesPrivateProfileAuthorization() async throws {
        try await withFixture { root, _, project in
            await project.open(root); try await settled(project)
            let profile = ConnectionProfile(name: "Synthetic", host: "synthetic.invalid", database: "example", username: "example", environment: .development)
            await project.bind(profile: profile, key: "manual-binding", schema: "public", candidateID: nil)
            try await settled(project)
            XCTAssertNotNil(project.binding(for: profile))
            try #"{"version":1,"bindings":{},"future":"preserved"}"#.write(to: root.appendingPathComponent(".db3/project.json"), atomically: true, encoding: .utf8)
            project.refresh(force: true)
            try await settled(project, until: { project.settings?.settings.bindings.isEmpty == true })
            XCTAssertNil(project.binding(for: profile))
            XCTAssertEqual(project.policyRestriction(for: profile), .unknown)
            XCTAssertFalse(project.bindings.isEmpty, "Keep unmatched private references for explicit review")
        }
    }

    func testChangingPortableSourceGroupRequiresReview() async throws {
        try await withFixture { root, _, project in
            try environment("synthetic-first").write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            await project.open(root); try await settled(project)
            let candidate = try XCTUnwrap(project.configuration?.candidates.first)
            let profile = candidate.reviewProfile()
            await project.bind(profile: profile, key: "local-app", schema: "public", candidateID: candidate.id)
            try await settled(project)
            try #"{"version":1,"bindings":{"local-app":{"sourceGroup":"PRODUCTION_DB_"}}}"#.write(to: root.appendingPathComponent(".db3/project.json"), atomically: true, encoding: .utf8)
            project.refresh(force: true)
            try await settled(project, until: { project.settings?.settings.bindings["local-app"]?.sourceGroup == "PRODUCTION_DB_" })
            XCTAssertNil(project.binding(for: profile))
            XCTAssertEqual(project.policyRestriction(for: profile), .unknown)
        }
    }

    func testInvalidExternalSettingsCannotContinueAuthorizingMetadata() async throws {
        try await withFixture { root, _, project in
            await project.open(root); try await settled(project)
            let profile = ConnectionProfile(name: "Synthetic", host: "synthetic.invalid", database: "example", username: "example", environment: .development)
            await project.bind(profile: profile, key: "manual-binding", schema: "public", candidateID: nil)
            try await settled(project)
            try #"{"version":1,"bindings":false}"#.write(to: root.appendingPathComponent(".db3/project.json"), atomically: true, encoding: .utf8)
            project.refresh(force: true)
            try await settled(project, until: { project.settingsError != nil })
            XCTAssertNil(project.binding(for: profile))
            XCTAssertEqual(project.policyRestriction(for: profile), .unknown)
        }
    }
}
