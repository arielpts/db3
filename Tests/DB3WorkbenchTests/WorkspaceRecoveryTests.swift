import Foundation
import XCTest
import Darwin
import CryptoKit
import DB3Core
@testable import DB3Workbench

final class WorkspaceRecoveryTests: XCTestCase, @unchecked Sendable {
    func testRoundTripKeepsDirtyUnicodeSQLSelectionOrderAndConnectionContext() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let sqlFile = fixture.directory.appendingPathComponent("existing query.sql")
        let original = "SELECT 'original file';\n"
        try original.write(to: sqlFile, atomically: true, encoding: .utf8)
        let originalDate = try FileManager.default.attributesOfItem(atPath: sqlFile.path)[.modificationDate] as? Date
        let sql = "-- café 🐘\nSELECT \"Δ\", 'unsaved';\n"
        let selection = (sql as NSString).range(of: "🐘")
        let profile = ConnectionProfile(name: "Dev database", host: "localhost", database: "development", username: "reader")
        let snapshot = WorkspaceSnapshot(tabs: [
            WorkspaceTabSnapshot(title: "Unsaved 🐘", sql: sql, savedSQL: original,
                fileURL: sqlFile, selectionLocation: selection.location, selectionLength: selection.length,
                profile: profile, database: "development", schema: "Sales\"EU", object: "Order.Items",
                allowsSpooling: false, resultTab: 1),
            WorkspaceTabSnapshot(title: "Untitled", sql: "SELECT 2;", savedSQL: "", isDemo: true)
        ], selectedTabIndex: 1, selectedBrowserProfileID: profile.id, showingInspector: true, nextUntitledNumber: 12)
        try await fixture.store.saveWorkspace(snapshot)
        let restored = try await fixture.store.loadWorkspace()
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(try String(contentsOf: sqlFile, encoding: .utf8), original)
        let finalDate = try FileManager.default.attributesOfItem(atPath: sqlFile.path)[.modificationDate] as? Date
        XCTAssertEqual(finalDate, originalDate, "Recovery saves must never write through to the user's SQL file.")
        XCTAssertNil(restored?.tabs[1].fileURL)
        XCTAssertTrue(restored?.tabs[1].isDemo == true)
        XCTAssertNotEqual(restored?.tabs[0].sql, restored?.tabs[0].savedSQL)
    }

    func testPrivateFileAndDirectoryPermissionsRemainPrivateOnReplacement() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let first = snapshot(sql: "SELECT 1;")
        try await fixture.store.saveWorkspace(first)
        XCTAssertEqual(try permissions(fixture.url), 0o600)
        XCTAssertEqual(try permissions(fixture.url.deletingLastPathComponent()), 0o700)
        try await fixture.store.saveWorkspace(snapshot(sql: "SELECT 2;"))
        XCTAssertEqual(try permissions(fixture.url), 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.url.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["workspace.json"], "Atomic-save temporary files must be removed.")
    }

    func testMissingWorkspaceDoesNotCreateAFileOrDirectory() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let recovered = try await fixture.store.loadWorkspace()
        XCTAssertNil(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.deletingLastPathComponent().path))
    }

    func testCorruptAndUnsupportedVersionFailWithoutChangingPriorBytes() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{\"tabs\": [truncated".utf8)
        try corrupt.write(to: fixture.url)
        await assertThrows { _ = try await fixture.store.loadWorkspace() }
        XCTAssertEqual(try Data(contentsOf: fixture.url), corrupt)
        let unsupported = WorkspaceSnapshot(version: 99, tabs: [])
        let encoded = try JSONEncoder().encode(unsupported)
        try encoded.write(to: fixture.url)
        do {
            _ = try await fixture.store.loadWorkspace()
            XCTFail("Future workspace versions must not be decoded as current state.")
        } catch WorkspaceRecoveryError.unsupportedVersion(let version) {
            XCTAssertEqual(version, 99)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), encoded)
    }

    func testInvalidSaveLeavesPreviousRecoveryFileUntouched() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let original = snapshot(sql: "SELECT 'recover me';")
        try await fixture.store.saveWorkspace(original)
        let bytes = try Data(contentsOf: fixture.url)
        let tooManyTabs = WorkspaceSnapshot(tabs: (0..<5).map { WorkspaceTabSnapshot(title: "Query \($0)", sql: "", savedSQL: "") })
        await assertThrows { try await fixture.store.saveWorkspace(tooManyTabs) }
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        let restored = try await fixture.store.loadWorkspace()
        XCTAssertEqual(restored, original)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.url.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["workspace.json"])
    }

    func testRenameFailurePreservesDestinationAndCleansPrivateTemporaryFile() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: true)
        let sentinel = fixture.url.appendingPathComponent("keep.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        await assertThrows { try await fixture.store.saveWorkspace(self.snapshot(sql: "SELECT 1;")) }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged")
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.url.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["workspace.json"])
    }

    func testOversizedReadIsRejectedBeforeDecodingAndPreserved() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: fixture.url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.truncate(atOffset: UInt64(WorkspaceSnapshot.maximumBytes + 1))
        try handle.close()
        do { _ = try await fixture.store.loadWorkspace(); XCTFail("An oversized recovery document must fail closed.") }
        catch WorkspaceRecoveryError.tooLarge { }
        let size = try FileManager.default.attributesOfItem(atPath: fixture.url.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, WorkspaceSnapshot.maximumBytes + 1)
    }

    func testEscapedOversizedSavePreservesPriorWorkspaceWithoutTruncatingSQL() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let original = snapshot(sql: "SELECT 'previous';")
        try await fixture.store.saveWorkspace(original)
        let bytes = try Data(contentsOf: fixture.url)
        // NUL requires six JSON bytes; the preflight catches this before JSON
        // encoding allocates an oversized document or touches the existing file.
        let sql = String(repeating: "\0", count: WorkspaceSnapshot.maximumBytes / 6 + 1)
        do { try await fixture.store.saveWorkspace(snapshot(sql: sql)); XCTFail("Oversized SQL must not be silently truncated.") }
        catch WorkspaceRecoveryError.tooLarge { }
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
    }

    func testUTF16BoundsAndSurrogateSplitsFailButEmojiSelectionRoundTrips() async throws {
        let store = MemoryWorkspaceRecoveryStore()
        let sql = "x🐘y"
        let valid = WorkspaceSnapshot(tabs: [.init(title: "Unicode", sql: sql, savedSQL: "", selectionLocation: 1, selectionLength: 2)])
        try await store.saveWorkspace(valid)
        for range in [NSRange(location: -1, length: 0), NSRange(location: 0, length: -1),
                      NSRange(location: Int.max, length: Int.max), NSRange(location: 4, length: 1),
                      NSRange(location: 2, length: 0), NSRange(location: 1, length: 1)] {
            let invalid = WorkspaceSnapshot(tabs: [.init(title: "Invalid", sql: sql, savedSQL: "",
                selectionLocation: range.location, selectionLength: range.length)])
            await assertThrows { try await store.saveWorkspace(invalid) }
            let recovered = try await store.loadWorkspace()
            XCTAssertEqual(recovered, valid)
        }
    }

    func testInvalidPaneSelectionTabIndexAndFileReferencesFailClosed() async throws {
        let store = MemoryWorkspaceRecoveryStore()
        let normal = WorkspaceTabSnapshot(title: "Query", sql: "", savedSQL: "")
        let invalidSnapshots = [
            WorkspaceSnapshot(tabs: [normal], selectedTabIndex: 1),
            WorkspaceSnapshot(tabs: [normal], selectedTabIndex: -1),
            WorkspaceSnapshot(tabs: [], selectedTabIndex: 1),
            WorkspaceSnapshot(tabs: [normal], nextUntitledNumber: 0),
            WorkspaceSnapshot(tabs: [normal], nextUntitledNumber: Int.max),
            WorkspaceSnapshot(tabs: [.init(title: "Query", sql: "", savedSQL: "", resultTab: 2)]),
            WorkspaceSnapshot(tabs: [.init(title: "Query", sql: "", savedSQL: "", fileURL: URL(string: "https://example.invalid/query.sql"))])
        ]
        for invalid in invalidSnapshots { await assertThrows { try await store.saveWorkspace(invalid) } }
        let loaded = try await store.loadWorkspace()
        XCTAssertNil(loaded)
        let empty = WorkspaceSnapshot(tabs: [])
        try await store.saveWorkspace(empty)
        let restored = try await store.loadWorkspace()
        XCTAssertEqual(restored, empty)
    }

    func testSerializedContractHasNoCredentialResultsOrLiveSessionFields() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let profile = ConnectionProfile(name: "Connection", host: "example.invalid", database: "db", username: "reader")
        try await fixture.store.saveWorkspace(WorkspaceSnapshot(tabs: [.init(title: "Query", sql: "SELECT 1;", savedSQL: "", profile: profile)]))
        let data = try Data(contentsOf: fixture.url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "tabs", "selectedTabIndex", "showingInspector", "nextUntitledNumber"])
        let tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
        XCTAssertEqual(Set(tabs[0].keys), ["title", "sql", "savedSQL", "selectionLocation", "selectionLength", "profile", "allowsSpooling", "resultTab", "isDemo"])
        let connection = try XCTUnwrap(tabs[0]["profile"] as? [String: Any])
        XCTAssertEqual(Set(connection.keys), ["id", "name", "host", "port", "database", "username", "tls", "rootCertificate", "defaultSchema", "environment"])
        XCTAssertEqual(connection["defaultSchema"] as? String, "public")
        XCTAssertEqual(connection["environment"] as? String, "unknown")
    }

    func testSymlinkRecoveryDocumentIsNotFollowed() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = fixture.directory.appendingPathComponent("unrelated.json")
        let bytes = try JSONEncoder().encode(snapshot(sql: "SELECT 'unrelated';"))
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)
        await assertThrows { _ = try await fixture.store.loadWorkspace() }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testSavingAfterCorruptOrFutureVersionPreservesExactPrivateBackups() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originals = [Data("{\"unfinished\":\"old draft 🐘\"".utf8),
            try JSONEncoder().encode(WorkspaceSnapshot(version: 999, tabs: [.init(title: "Future", sql: "SELECT 'keep this';", savedSQL: "")]))]
        var expectedBackups: [Data] = []
        for (index, bytes) in originals.enumerated() {
            try bytes.write(to: fixture.url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url.path)
            let current = snapshot(sql: "SELECT 'current draft \(index)';")
            try await fixture.store.saveWorkspace(current)
            let restored = try await fixture.store.loadWorkspace()
            XCTAssertEqual(restored, current)
            expectedBackups.append(bytes)
            let backups = try backupURLs(fixture)
            XCTAssertEqual(backups.count, expectedBackups.count)
            let actualBackups = try backups.map { try Data(contentsOf: $0) }
            XCTAssertEqual(Set(actualBackups), Set(expectedBackups))
            for backup in backups { XCTAssertEqual(try permissions(backup), 0o600) }
            XCTAssertEqual(try permissions(fixture.url), 0o600)
        }
        // Replacing readable current state leaves all existing backups intact
        // and does not turn normal quits into an unbounded history of copies.
        try await fixture.store.saveWorkspace(snapshot(sql: "SELECT 'normal replacement';"))
        XCTAssertEqual(try backupURLs(fixture).count, originals.count)
    }

    func testOversizedOriginalIsBackedUpAsExactHardLinkBeforeReplacement() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: fixture.url.path, contents: nil))
        let size = UInt64(WorkspaceSnapshot.maximumBytes + 100)
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.write(contentsOf: Data("original-start".utf8))
        try handle.truncate(atOffset: size)
        try handle.seek(toOffset: size - 12)
        try handle.write(contentsOf: Data("original-end".utf8))
        try handle.close()
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        let originalDigest = try digest(fixture.url)
        let current = snapshot(sql: "SELECT 'new valid draft';")
        try await fixture.store.saveWorkspace(current)
        let backups = try backupURLs(fixture)
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual(backupAttributes[.systemFileNumber] as? NSNumber, originalAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(backupAttributes[.size] as? NSNumber, NSNumber(value: size))
        XCTAssertEqual(try digest(backup), originalDigest)
        XCTAssertEqual(try permissions(backup), 0o600)
        let restored = try await fixture.store.loadWorkspace()
        XCTAssertEqual(restored, current)
    }

    func testSavingRefusesSymlinkInsteadOfReplacingOrBackingUpItsTarget() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = fixture.directory.appendingPathComponent("unrelated.json")
        let bytes = Data("unrelated original bytes".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)
        await assertThrows { try await fixture.store.saveWorkspace(self.snapshot(sql: "SELECT 1;")) }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url.path), target.path)
        XCTAssertTrue(try backupURLs(fixture).isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.url.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["workspace.json"])
    }

    func testFailedBackupLinkLeavesOriginalAndRemovesTemporaryReplacement() async throws {
        let fixture = try RecoveryFixture()
        defer { Darwin.chflags(fixture.url.path, 0); fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ unreadable original draft".utf8)
        try original.write(to: fixture.url)
        // The immutable flag prevents creating a hard link on this isolated
        // fixture. It is always removed in defer before the fixture is deleted.
        guard Darwin.chflags(fixture.url.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw XCTSkip("This test filesystem does not support user immutable flags.")
        }
        await assertThrows { try await fixture.store.saveWorkspace(self.snapshot(sql: "SELECT 'new draft';")) }
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertTrue(try backupURLs(fixture).isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.url.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["workspace.json"])
    }

    private func snapshot(sql: String) -> WorkspaceSnapshot {
        WorkspaceSnapshot(tabs: [WorkspaceTabSnapshot(title: "Query 1", sql: sql, savedSQL: "")])
    }
    private func permissions(_ url: URL) throws -> Int {
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        return mode.intValue & 0o777
    }
    private func backupURLs(_ fixture: RecoveryFixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixture.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("workspace-unreadable-") && $0.pathExtension == "json" }
    }
    private func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize()
    }
    private func assertThrows(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected a recovery failure", file: file, line: line) } catch { }
    }
}

private struct RecoveryFixture: Sendable {
    let directory: URL
    let url: URL
    let store: LocalWorkspaceRecoveryStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("db3-workspace-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("recovery", isDirectory: true).appendingPathComponent("workspace.json")
        store = LocalWorkspaceRecoveryStore(url: url)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
