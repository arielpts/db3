import DB3Core
import DB3Results
import Foundation
import Testing

struct ResultStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("db3-result-tests-" + UUID().uuidString, isDirectory: true)
    }

    @Test func evictedPagesPreserveNullEmptyUnicodeAndExactNumerics() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(residentByteLimit: 180, directory: directory, pageRowLimit: 1))
        let original: [DatabaseRow] = [
            [.null, .text(""), .text("999999999999999999999999999999.12345678901234567890")],
            [.text("東京 🐘"), .text("line one\nline two\u{0}tail"), .text("NaN")],
            [.text("\\x00ff"), .text("2026-09-29 12:34:56.123456+00"), .null],
        ]
        #expect(try await store.append(RowBatch(rows: original)) == original.count)
        let stats = await store.statistics()
        #expect(stats.rows == 3)
        #expect(stats.pages == 3)
        #expect(stats.residentBytes <= 180)
        #expect(stats.spooledBytes > 0)
        #expect(try await store.rows(in: 2..<3) == [original[2]])
        #expect(try await store.rows(in: 0..<2) == Array(original.prefix(2)))
        #expect(try await store.rows(in: 0..<100) == original)
        #expect(await store.statistics().residentBytes <= 180)
        await store.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func quotaFailureRollsBackEntireBatchAndPreservesEarlierRows() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(residentByteLimit: 0, spoolByteLimit: 75, directory: directory, pageRowLimit: 1))
        let row: DatabaseRow = [.text("0123456789")]
        try await store.append(RowBatch(rows: [row])) // 30 encoded bytes.
        let before = await store.statistics()
        do {
            try await store.append(RowBatch(rows: [row, row])) // First page fits; second must roll back.
            Issue.record("Expected quota exhaustion")
        } catch let error as ResultStoreError {
            #expect(error == .spoolQuota(limit: 75))
        }
        #expect(await store.statistics() == before)
        #expect(try await store.rows(in: 0..<100) == [row])
        let spool = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: spool.appendingPathComponent("pages.bin").path)
        #expect((fileAttributes[.size] as? NSNumber)?.intValue == before.spooledBytes)
        // A failed write does not poison the store: a later smaller batch still fits.
        try await store.append(RowBatch(rows: [[.null]]))
        #expect(try await store.rows(in: 0..<10) == [row, [.null]])
        await store.close()
    }

    @Test func noSpoolModeStopsBeforeEvictionOrFilesystemCreation() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(residentByteLimit: 200, allowsSpooling: false, directory: directory, pageRowLimit: 1))
        let row: DatabaseRow = [.text(String(repeating: "a", count: 100))]
        try await store.append(RowBatch(rows: [row]))
        do {
            try await store.append(RowBatch(rows: [[.null]]))
            Issue.record("Expected no-spool memory limit")
        } catch let error as ResultStoreError {
            #expect(error == .memoryLimit(limit: 200))
        }
        #expect(await store.rowCount() == 1)
        #expect(await store.statistics().spooledBytes == 0)
        #expect(try await store.rows(in: 0..<10) == [row])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await store.close()
    }

    @Test func resetAndCloseRemovePrivateFiles() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(directory: directory))
        try await store.append(RowBatch(rows: [[.text("private value")]]))
        let spool = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: spool.path)
        let dataAttributes = try FileManager.default.attributesOfItem(atPath: spool.appendingPathComponent("pages.bin").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((dataAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await store.reset()
        #expect(await store.rowCount() == 0)
        #expect(await store.statistics().spooledBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: spool.path))
        try await store.append(RowBatch(rows: [[.text("new result")]]))
        #expect(try await store.rows(in: 0..<10) == [[.text("new result")]])
        await store.close()
        await store.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        do {
            try await store.append(RowBatch(rows: [[.null]]))
            Issue.record("Expected closed store")
        } catch let error as ResultStoreError { #expect(error == .closed) }
    }

    @Test func abandonedSpoolsAreRemovedWithoutTouchingLiveStores() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ResultStore(configuration: .init(residentByteLimit: 0, directory: directory))
        try await first.append(RowBatch(rows: [[.text("still open")]]))
        let abandoned = directory.appendingPathComponent("result-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        #expect(FileManager.default.createFile(atPath: abandoned.appendingPathComponent("lease").path, contents: Data()))
        let second = ResultStore(configuration: .init(residentByteLimit: 0, directory: directory))
        try await second.append(RowBatch(rows: [[.text("second result")]]))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try await first.rows(in: 0..<1) == [[.text("still open")]])
        #expect(try await second.rows(in: 0..<1) == [[.text("second result")]])
        await first.close()
        await second.close()
    }

    @Test func cancelledAdmissionAndOversizedBatchDoNotChangeResult() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(directory: directory, maximumBatchBytes: 128))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.append(RowBatch(rows: [[.null]]))
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(await store.rowCount() == 0)
        do {
            try await store.append(RowBatch(rows: [[.text(String(repeating: "x", count: 100))]]))
            Issue.record("Expected bounded batch rejection")
        } catch let error as ResultStoreError { #expect(error == .batchLimit(limit: 128)) }
        #expect(await store.rowCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await store.close()
    }

    @Test func corruptedSpoolFailsClearlyAndReadRequestsAreBounded() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(residentByteLimit: 0, directory: directory, maximumReadRows: 1))
        try await store.append(RowBatch(rows: [[.null], [.text("two")]]))
        do {
            _ = try await store.rows(in: 0..<2)
            Issue.record("Expected bounded read rejection")
        } catch let error as ResultStoreError { #expect(error == .readLimit) }
        let spool = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let file = try FileHandle(forWritingTo: spool.appendingPathComponent("pages.bin"))
        try file.truncate(atOffset: 2)
        try file.close()
        do {
            _ = try await store.rows(in: 0..<1)
            Issue.record("Expected corrupt-spool error")
        } catch let error as ResultStoreError { #expect(error == .corruptSpool) }
        await store.close()
    }

    @Test func sharedQuotaAllowsOneStoreToBorrowCapacityAndReleasesOnResetAndClose() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = ResultStore.SpoolBudget(byteLimit: 100)
        let configuration = ResultStore.Configuration(residentByteLimit: 0, sharedSpoolBudget: budget, directory: directory, pageRowLimit: 1)
        let first = ResultStore(configuration: configuration)
        let second = ResultStore(configuration: configuration)
        let row: DatabaseRow = [.text("0123456789")] // 30 encoded bytes per page.
        try await first.append(RowBatch(rows: [row, row]))
        #expect(budget.usedBytes == 60) // More than half the shared quota is usable by one store.
        try await second.append(RowBatch(rows: [row]))
        #expect(budget.usedBytes == 90)
        do {
            try await second.append(RowBatch(rows: [[.null]]))
            Issue.record("Expected combined quota exhaustion")
        } catch let error as ResultStoreError { #expect(error == .spoolQuota(limit: 100)) }
        #expect(budget.usedBytes == 90)
        #expect(try await first.rows(in: 0..<10) == [row, row])
        #expect(try await second.rows(in: 0..<10) == [row])
        try await first.reset()
        #expect(budget.usedBytes == 30)
        try await second.append(RowBatch(rows: [row, row]))
        #expect(budget.usedBytes == 90)
        await second.close()
        #expect(budget.usedBytes == 0)
        await first.close()
        #expect(budget.usedBytes == 0)
    }

    @Test func sharedQuotaRollsBackReservationsFromEarlierPagesOfRejectedBatch() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = ResultStore.SpoolBudget(byteLimit: 75)
        let configuration = ResultStore.Configuration(residentByteLimit: 0, sharedSpoolBudget: budget, directory: directory, pageRowLimit: 1)
        let first = ResultStore(configuration: configuration)
        let second = ResultStore(configuration: configuration)
        let row: DatabaseRow = [.text("0123456789")]
        try await first.append(RowBatch(rows: [row]))
        do {
            try await second.append(RowBatch(rows: [row, row]))
            Issue.record("Expected atomic shared quota rollback")
        } catch let error as ResultStoreError { #expect(error == .spoolQuota(limit: 75)) }
        #expect(budget.usedBytes == 30)
        #expect(await second.rowCount() == 0)
        try await first.append(RowBatch(rows: [row]))
        #expect(budget.usedBytes == 60)
        await first.close()
        await second.close()
        #expect(budget.usedBytes == 0)
    }

    @Test func simultaneousStoresCannotOverbookSharedQuota() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = ResultStore.SpoolBudget(byteLimit: 50)
        let configuration = ResultStore.Configuration(sharedSpoolBudget: budget, directory: directory)
        let stores = [ResultStore(configuration: configuration), ResultStore(configuration: configuration)]
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for store in stores {
                group.addTask {
                    do {
                        try await store.append(RowBatch(rows: [[.text("0123456789")]]))
                        return true
                    } catch let error as ResultStoreError {
                        #expect(error == .spoolQuota(limit: 50))
                        return false
                    } catch {
                        Issue.record("Unexpected concurrent append failure: \(error)")
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(budget.usedBytes == 30)
        for store in stores { await store.close() }
        #expect(budget.usedBytes == 0)
    }

    @Test func csvExportPreservesExactValuesNullsAndQuotingAcrossEvictedPages() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(residentByteLimit: 0, directory: directory, pageRowLimit: 1))
        let numeric = "999999999999999999999999.000000000000000001"
        try await store.append(RowBatch(rows: [
            [.null, .text(""), .text("comma, quote\" and\n東京 🐘")],
            [.text("NULL"), .text(numeric), .text("\\N")],
        ]))
        let destination = directory.appendingPathComponent("export.csv")
        try Data("previous file".utf8).write(to: destination)
        let columns = [DatabaseColumn(index: 0, name: "nullable"), DatabaseColumn(index: 1, name: "number"), DatabaseColumn(index: 2, name: "text,\"header")]
        #expect(try await store.exportCSV(columns: columns, to: destination) == 2)
        let actual = try String(contentsOf: destination, encoding: .utf8)
        let expected = "\"nullable\",\"number\",\"text,\"\"header\"\r\n,\"\",\"comma, quote\"\" and\n東京 🐘\"\r\n\"NULL\",\"\(numeric)\",\"\\N\"\r\n"
        #expect(actual == expected)
        #expect(await store.statistics().residentBytes == 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".db3-export-") })
        await store.close()
        #expect(try String(contentsOf: destination, encoding: .utf8) == expected)
    }

    @Test func csvExportFailureKeepsExistingDestinationAndRemovesTemporaryFile() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(directory: directory))
        try await store.append(RowBatch(rows: [[.text("first"), .text("second")]]))
        let destination = directory.appendingPathComponent("existing.csv")
        try Data("keep this file".utf8).write(to: destination)
        do {
            try await store.exportCSV(columns: [DatabaseColumn(index: 0, name: "one header")], to: destination)
            Issue.record("Expected CSV shape validation failure")
        } catch let error as ResultStoreError { #expect(error == .columnCount(expected: 1, actual: 2)) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep this file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".db3-export-") })
        await store.close()
    }

    @Test func cancellingActiveCSVExportKeepsExistingDestination() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore(configuration: .init(residentByteLimit: 0, directory: directory))
        // Quoting doubles this field on disk. Encoding must stay cancellable and
        // cannot allocate a second full output-sized string.
        try await store.append(RowBatch(rows: [[.text(String(repeating: "\"", count: 6 * 1_024 * 1_024))]]))
        let destination = directory.appendingPathComponent("existing.csv")
        try Data("keep this file".utf8).write(to: destination)
        let task = Task { try await store.exportCSV(columns: [DatabaseColumn(index: 0, name: "value")], to: destination) }
        var started = false
        for _ in 0..<2_000 {
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".db3-export-") }) {
                started = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(started)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected active export cancellation") }
        catch is CancellationError { }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep this file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".db3-export-") })
        #expect(await store.rowCount() == 1)
        await store.close()
    }
}
