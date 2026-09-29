import Foundation
import Darwin
import XCTest
@testable import DB3Projects

final class ProjectSettingsStoreTests: XCTestCase, @unchecked Sendable {
    func testUnknownFieldsAndOrphanOverridesSurviveRoundTrip() async throws {
        let folder = try ProjectConfigTestFolder()
        try folder.write(".db3/project.json", #"""
        {
          "version": 1,
          "adapter": "odoo",
          "future": {"largeInteger": 9007199254740993, "enabled": true, "items": [null, "value"]},
          "namespaces": {"showBase": false, "futureColor": "orange"},
          "bindings": {"local-app": {"sourceGroup": "DB_", "futurePriority": 9}},
          "objectOverrides": [{"binding": "local-app", "schema": "public", "relation": "old_table", "namespace": "sales", "futureOrder": 2}]
        }
        """#)
        let store = ProjectSettingsStore(root: folder.url)
        var document = try await store.load()
        document.settings.namespaces.showBase = true
        document.settings.namespaces.displayNames = ["sales": "Sales"]
        let saved = try await store.save(document)
        XCTAssertNotEqual(saved.digest, document.digest)
        let reopened = try await ProjectSettingsStore(root: folder.url).load()
        XCTAssertTrue(reopened.settings.namespaces.showBase)
        XCTAssertEqual(reopened.settings.objectOverrides, document.settings.objectOverrides)
        let bytes = try Data(contentsOf: store.fileURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let future = try XCTUnwrap(json["future"] as? [String: Any])
        XCTAssertEqual((future["largeInteger"] as? NSNumber)?.stringValue, "9007199254740993")
        XCTAssertEqual((json["namespaces"] as? [String: Any])?["futureColor"] as? String, "orange")
        XCTAssertEqual(((json["bindings"] as? [String: Any])?["local-app"] as? [String: Any])?["futurePriority"] as? Int, 9)
        XCTAssertEqual((json["objectOverrides"] as? [[String: Any]])?.first?["futureOrder"] as? Int, 2)
        for forbidden in ["password", "endpoint", "profileID", "relationOID", "bookmark"] {
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(forbidden))
        }
    }

    func testExternalEditAndConcurrentFirstSaveAreConflicts() async throws {
        let folder = try ProjectConfigTestFolder()
        let store = ProjectSettingsStore(root: folder.url)
        var document = try await store.load()
        XCTAssertNil(document.digest)
        try folder.write(".db3/project.json", #"{"version":1,"external":"preserve"}"#)
        document.settings.namespaces.showBase = true
        do { _ = try await store.save(document); XCTFail("Missing-file snapshot overwrote external creation") }
        catch { XCTAssertEqual(error as? ProjectSettingsError, .conflict) }
        var loaded = try await store.load()
        loaded.settings.adapter = "odoo"
        let external = #"{"version":1,"external":"changed-again"}"#
        try folder.write(".db3/project.json", external)
        do { _ = try await store.save(loaded); XCTFail("Stale revision overwrote external edit") }
        catch { XCTAssertEqual(error as? ProjectSettingsError, .conflict) }
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), external)
    }

    func testUnsupportedVersionAndWrongKnownTypesFailWithoutRewrite() async throws {
        for json in [#"{"version":99,"keep":true}"#, #"{"version":1,"namespaces":false}"#,
                     #"{"version":1,"namespaces":{"showBase":"yes"}}"#, #"{"version":1,"bindings":[]}"#,
                     #"{"version":1,"objectOverrides":"invalid"}"#, #"{"version":1,"adapter":123}"#] {
            let folder = try ProjectConfigTestFolder()
            try folder.write(".db3/project.json", json)
            let store = ProjectSettingsStore(root: folder.url)
            do { _ = try await store.load(); XCTFail("Accepted invalid settings \(json)") }
            catch { XCTAssertTrue(error is ProjectSettingsError) }
            XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), json)
        }
    }

    func testReadOnlyFolderReportsUnsavedAndPreservesOriginal() async throws {
        let folder = try ProjectConfigTestFolder()
        try folder.write(".db3/project.json", #"{"version":1}"#)
        let store = ProjectSettingsStore(root: folder.url)
        var document = try await store.load(); document.settings.namespaces.showBase = true
        let directory = folder.url.appendingPathComponent(".db3")
        XCTAssertEqual(chmod(directory.path, 0o555), 0)
        defer { _ = chmod(directory.path, 0o755) }
        do { _ = try await store.save(document); XCTFail("Read-only settings falsely reported saved") }
        catch { XCTAssertEqual(error as? ProjectSettingsError, .readOnly) }
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), #"{"version":1}"#)
    }

    func testSymlinkSettingsDirectoryAndFileCannotEscapeRoot() async throws {
        let folder = try ProjectConfigTestFolder(), outside = try ProjectConfigTestFolder()
        try outside.write("project.json", #"{"version":1}"#)
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent(".db3"), withDestinationURL: outside.url)
        let store = ProjectSettingsStore(root: folder.url)
        do { _ = try await store.load(); XCTFail("Followed settings directory symlink") }
        catch { XCTAssertEqual(error as? ProjectSettingsError, .unavailable) }
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent(".db3"))
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent(".db3"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: outside.url.appendingPathComponent("project.json"))
        do { _ = try await store.save(ProjectSettingsDocument()); XCTFail("Replaced settings file symlink") }
        catch { XCTAssertEqual(error as? ProjectSettingsError, .unavailable) }
        XCTAssertEqual(try String(contentsOf: outside.url.appendingPathComponent("project.json"), encoding: .utf8), #"{"version":1}"#)
    }

    func testAtomicFailureDoesNotLeaveTemporaryFilesOrDestroyDestination() throws {
        let folder = try ProjectConfigTestFolder()
        let destination = folder.url.appendingPathComponent("project.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ProjectAtomicFile.write(Data("{}".utf8), to: destination, permissions: 0o644))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path), ["project.json"])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPrivateBindingPersistsOutsideProjectAndRelocationPreservesIdentity() async throws {
        let privateFolder = try ProjectConfigTestFolder(), project = try ProjectConfigTestFolder(), relocated = try ProjectConfigTestFolder()
        let directory = privateFolder.url.appendingPathComponent("private")
        let store = ProjectPrivateStore(directory: directory)
        let recent = try await store.remember(root: project.url)
        let profileID = UUID()
        let binding = ProjectPrivateBinding(profileID: profileID, endpointFingerprint: "synthetic-endpoint-digest",
            candidateID: ".env:DB_", candidateFingerprint: "synthetic-nonsecret-digest", databaseOID: 44,
            objects: [.init(schema: "public", relation: "example", databaseOID: 44, schemaOID: 2200, relationOID: 55, identityToken: "123")])
        try await store.bind(projectID: recent.id, key: "local-app", binding: binding)
        let moved = try await store.remember(root: relocated.url, replacing: recent.id)
        XCTAssertEqual(moved.id, recent.id)
        XCTAssertNotEqual(moved.rootIdentity, recent.rootIdentity)
        try await store.setActiveProject(nil)
        let reopened = try await ProjectPrivateStore(directory: directory).load()
        XCTAssertNil(reopened.activeProjectID)
        XCTAssertEqual(reopened.bindings[recent.id.uuidString]?["local-app"], binding)
        XCTAssertEqual(reopened.recents.count, 1)
        let resolved = try await store.resolve(moved)
        XCTAssertEqual(resolved.url.standardizedFileURL.path, relocated.url.standardizedFileURL.path)
        let info = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirInfo = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((dirInfo[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(json.contains("secretRevision"))
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.url.appendingPathComponent(".db3").path))
    }
}
