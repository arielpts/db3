import DB3Core
import DB3Postgres
import DB3Results
import Darwin
import Foundation

/// Headless driver + bounded store workload. This does not measure AppKit,
/// application launch, UI responsiveness, or the PostgreSQL server's memory.
@main
struct DB3Benchmark {
    static func main() async {
        do {
            let report = try await run()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } catch {
            let message = "DB3 benchmark failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func run() async throws -> BenchmarkReport {
        let environment = ProcessInfo.processInfo.environment
        let rows = try integer(environment, "DB3_BENCH_ROWS", default: 1_000_000, allowed: 1...10_000_000)
        let port = try integer(environment, "DB3_TEST_PORT", default: 55439, allowed: 1...65535)
        let residentMiB = try integer(environment, "DB3_BENCH_RESIDENT_MIB", default: 16, allowed: 1...1024)
        let spoolMiB = try integer(environment, "DB3_BENCH_SPOOL_MIB", default: 512, allowed: 1...16384)
        let delayMS = try integer(environment, "DB3_BENCH_CONSUMER_DELAY_MS", default: 0, allowed: 0...1000)
        let configuration = ResultStore.Configuration(
            residentByteLimit: residentMiB * 1_024 * 1_024,
            spoolByteLimit: spoolMiB * 1_024 * 1_024
        )
        let store = ResultStore(configuration: configuration)
        let session = PostgresSession()
        let processMemoryAtStart = ProcessMemory.read()
        let profile = ConnectionProfile(
            name: "Headless benchmark", host: environment["DB3_TEST_HOST"] ?? "127.0.0.1",
            port: port, database: environment["DB3_TEST_DATABASE"] ?? "postgres",
            username: environment["DB3_TEST_USER"] ?? "ariel", tls: .disable
        )

        do {
            let connectStart = DispatchTime.now().uptimeNanoseconds
            let server = try await session.connect(profile: profile, password: environment["DB3_TEST_PASSWORD"] ?? "")
            let connectionSeconds = seconds(since: connectStart)
            let start = DispatchTime.now().uptimeNanoseconds
            let progress = Progress(start: start)
            let summary = try await session.execute(sql: workloadSQL(rows: rows)) { event in
                switch event {
                case .columns(let columns): await progress.columns(columns.count)
                case .rows(let batch):
                    await progress.received(batch)
                    if delayMS > 0 { try await Task.sleep(for: .milliseconds(delayMS)) }
                    _ = try await store.append(batch)
                    await progress.committed()
                case .notice: break
                }
            }
            let streamSeconds = seconds(since: start)
            let progressSnapshot = await progress.snapshot()
            let storage = await store.statistics()
            let processMemoryAfterStream = ProcessMemory.read()
            guard summary.rowCount == rows, storage.rows == rows,
                  progressSnapshot.rowCount == rows, progressSnapshot.columnCount == 8 else {
                throw BenchmarkFailure("Driver or store row/column totals do not match the fixture.")
            }
            guard storage.residentBytes <= configuration.residentByteLimit else {
                throw BenchmarkFailure("Resident page accounting exceeded its configured limit.")
            }

            let inspectionStart = DispatchTime.now().uptimeNanoseconds
            let first = try await store.rows(in: 0..<1)
            let last = try await store.rows(in: (rows - 1)..<rows)
            guard first == [expectedRow(1)], last == [expectedRow(rows)] else {
                throw BenchmarkFailure("First/last rows did not round-trip exactly through the result store.")
            }
            let inspectionSeconds = seconds(since: inspectionStart)
            // For the default million-row run, the earliest page is necessarily
            // evicted. Small smoke runs explicitly report no eviction evidence.
            let evictionExercised = storage.spooledBytes > configuration.residentByteLimit
            let cancellation: CancellationReport?
            if environment["DB3_BENCH_CANCEL"] == "0" {
                cancellation = nil
            } else {
                cancellation = try await checkCancellation(session: session)
            }
            await store.close()
            await session.disconnect()
            let processMemoryAfterCleanup = ProcessMemory.read()

            return BenchmarkReport(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                hardware: machineModel(), architecture: architecture, systemMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                buildConfiguration: buildConfiguration,
                serverVersion: server.serverVersion, workload: "generate_series, 8 scalar/text columns, approximately 256 payload bytes per row",
                requestedRows: rows, rowCount: storage.rows, columnCount: progressSnapshot.columnCount,
                batchCount: progressSnapshot.batchCount, maxBatchRows: progressSnapshot.maxBatchRows,
                maxBatchPayloadBytes: progressSnapshot.maxBatchPayloadBytes,
                residentByteLimit: configuration.residentByteLimit, spoolByteLimit: configuration.spoolByteLimit,
                residentBytesAtStreamCompletion: storage.residentBytes, spooledBytes: storage.spooledBytes, pages: storage.pages,
                consumerDelayMilliseconds: delayMS, connectionSeconds: connectionSeconds,
                firstBatchReceivedSeconds: progressSnapshot.firstBatchReceivedSeconds,
                firstBatchStoredSeconds: progressSnapshot.firstBatchStoredSeconds,
                streamAndSpoolSeconds: streamSeconds, rowsPerSecond: Double(rows) / streamSeconds,
                endpointInspectionSeconds: inspectionSeconds, exactEndpointValuesVerified: true,
                endpointInspectionExercisedEviction: evictionExercised,
                processMemoryAtStart: processMemoryAtStart, processMemoryAfterStream: processMemoryAfterStream,
                processMemoryAfterCleanup: processMemoryAfterCleanup, cancellation: cancellation,
                limitations: [
                    "Single headless sample; excludes app launch, grid/editor rendering, input latency, and server process memory.",
                    "Physical footprint and resident set are different OS metrics. Peak values are kernel process-lifetime peaks, not baseline-subtracted allocations.",
                    "ResultStore residentBytes is payload/container accounting, not process memory.",
                    "Server execution and local transport are included in first-batch and stream durations; the consumer's configured delay is included.",
                    "Run Release repeatedly on the stated reference hardware before assessing performance budgets."
                ]
            )
        } catch {
            await store.close()
            await session.disconnect()
            throw error
        }
    }

    private static func checkCancellation(session: PostgresSession) async throws -> CancellationReport {
        let collector = Progress(start: DispatchTime.now().uptimeNanoseconds)
        let pending = Task {
            try await session.execute(sql: "SELECT pg_sleep(30)") { event in
                if case .rows(let batch) = event { await collector.received(batch) }
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        let cancelStart = DispatchTime.now().uptimeNanoseconds
        await session.cancel()
        let acknowledgementSeconds = seconds(since: cancelStart)
        var sqlState: String?
        do {
            _ = try await pending.value
            throw BenchmarkFailure("The sleeping query completed instead of being cancelled.")
        } catch let error as DatabaseError {
            guard error.sqlState == "57014" else { throw error }
            sqlState = error.sqlState
        } catch is CancellationError {
            sqlState = "Task cancellation"
        }
        let recoverySeconds = seconds(since: cancelStart)
        let deliveredRows = await collector.snapshot().rowCount
        guard deliveredRows == 0 else { throw BenchmarkFailure("The cancellation fixture delivered rows before cancellation.") }
        let next = try await session.execute(sql: "SELECT 42") { _ in }
        guard next.rowCount == 1, next.transaction == .idle else {
            throw BenchmarkFailure("The session did not execute successfully after cancellation.")
        }
        return CancellationReport(
            requestAcknowledgementSeconds: acknowledgementSeconds, recoverySeconds: recoverySeconds,
            rowsBeforeCancellation: deliveredRows, sqlState: sqlState, subsequentQuerySucceeded: true
        )
    }

    private static func workloadSQL(rows: Int) -> String {
        """
        SELECT i::bigint AS id,
               (i % 1000)::integer AS bucket,
               (i / 10.0)::numeric(20,4) AS exact_amount,
               (i % 2 = 0) AS enabled,
               CASE WHEN i % 10 = 0 THEN NULL::text ELSE ''::text END AS nullable_empty,
               repeat('x', 100) AS payload_a,
               repeat('y', 128) AS payload_b,
               'ação 🐘'::text AS unicode
        FROM generate_series(1, \(rows)) AS fixture(i)
        """
    }

    private static func expectedRow(_ index: Int) -> DatabaseRow {
        let fraction = String(format: "%04d", (index % 10) * 1000)
        return [
            .text(String(index)), .text(String(index % 1000)), .text("\(index / 10).\(fraction)"),
            .text(index % 2 == 0 ? "t" : "f"), index % 10 == 0 ? .null : .text(""),
            .text(String(repeating: "x", count: 100)), .text(String(repeating: "y", count: 128)), .text("ação 🐘")
        ]
    }

    private static func integer(_ environment: [String: String], _ key: String, default fallback: Int, allowed: ClosedRange<Int>) throws -> Int {
        guard let text = environment[key] else { return fallback }
        guard let value = Int(text), allowed.contains(value) else {
            throw BenchmarkFailure("\(key) must be an integer in \(allowed.lowerBound)...\(allowed.upperBound).")
        }
        return value
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "Unknown"
        #endif
    }
}

private actor Progress {
    struct Snapshot: Sendable {
        var rowCount = 0
        var columnCount = 0
        var batchCount = 0
        var maxBatchRows = 0
        var maxBatchPayloadBytes = 0
        var firstBatchReceivedSeconds: Double?
        var firstBatchStoredSeconds: Double?
    }
    let start: UInt64
    var value = Snapshot()
    init(start: UInt64) { self.start = start }
    func columns(_ count: Int) { value.columnCount = count }
    func received(_ batch: RowBatch) {
        if value.firstBatchReceivedSeconds == nil { value.firstBatchReceivedSeconds = seconds(since: start) }
        value.rowCount += batch.rows.count
        value.batchCount += 1
        value.maxBatchRows = max(value.maxBatchRows, batch.rows.count)
        value.maxBatchPayloadBytes = max(value.maxBatchPayloadBytes, batch.byteCount)
    }
    func committed() {
        if value.firstBatchStoredSeconds == nil { value.firstBatchStoredSeconds = seconds(since: start) }
    }
    func snapshot() -> Snapshot { value }
}

private struct ProcessMemory: Codable, Sendable {
    var physicalFootprintBytes: UInt64?
    var physicalFootprintLifetimePeakBytes: UInt64?
    var residentSetBytes: UInt64?
    var residentSetLifetimePeakBytes: UInt64?

    static func read() -> ProcessMemory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        var usage = rusage()
        let usageStatus = getrusage(RUSAGE_SELF, &usage)
        return ProcessMemory(
            physicalFootprintBytes: result == KERN_SUCCESS ? info.phys_footprint : nil,
            physicalFootprintLifetimePeakBytes: result == KERN_SUCCESS ? UInt64(max(0, info.ledger_phys_footprint_peak)) : nil,
            residentSetBytes: result == KERN_SUCCESS ? info.resident_size : nil,
            // Darwin reports ru_maxrss in bytes (Linux uses KiB).
            residentSetLifetimePeakBytes: usageStatus == 0 ? UInt64(max(0, usage.ru_maxrss)) : nil
        )
    }
}

private struct CancellationReport: Codable, Sendable {
    let requestAcknowledgementSeconds: Double
    let recoverySeconds: Double
    let rowsBeforeCancellation: Int
    let sqlState: String?
    let subsequentQuerySucceeded: Bool
}

private struct BenchmarkReport: Codable, Sendable {
    let timestamp: String
    let operatingSystem: String
    let hardware: String
    let architecture: String
    let systemMemoryBytes: UInt64
    let buildConfiguration: String
    let serverVersion: String
    let workload: String
    let requestedRows: Int
    let rowCount: Int
    let columnCount: Int
    let batchCount: Int
    let maxBatchRows: Int
    let maxBatchPayloadBytes: Int
    let residentByteLimit: Int
    let spoolByteLimit: Int
    let residentBytesAtStreamCompletion: Int
    let spooledBytes: Int
    let pages: Int
    let consumerDelayMilliseconds: Int
    let connectionSeconds: Double
    let firstBatchReceivedSeconds: Double?
    let firstBatchStoredSeconds: Double?
    let streamAndSpoolSeconds: Double
    let rowsPerSecond: Double
    let endpointInspectionSeconds: Double
    let exactEndpointValuesVerified: Bool
    let endpointInspectionExercisedEviction: Bool
    let processMemoryAtStart: ProcessMemory
    let processMemoryAfterStream: ProcessMemory
    let processMemoryAfterCleanup: ProcessMemory
    let cancellation: CancellationReport?
    let limitations: [String]
}

private struct BenchmarkFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func seconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

private func machineModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return "Unknown" }
    return value.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
