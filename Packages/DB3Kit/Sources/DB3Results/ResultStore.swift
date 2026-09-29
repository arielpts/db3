import DB3Core
import Foundation
import Darwin

public enum ResultStoreError: Error, LocalizedError, Sendable, Equatable {
    case closed
    case busy
    case memoryLimit(limit: Int)
    case spoolQuota(limit: Int)
    case batchLimit(limit: Int)
    case pageLimit(limit: Int)
    case readLimit
    case invalidRange
    case corruptSpool
    case columnCount(expected: Int, actual: Int)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .closed: "This result has been closed."
        case .busy: "The result store is busy. Wait for the current page operation and retry."
        case .memoryLimit(let limit): "No-spool memory limit (\(limit) bytes) reached. The result is incomplete; previous rows remain available."
        case .spoolQuota(let limit): "Temporary result quota (\(limit) bytes) reached. The result is incomplete; previous rows remain available."
        case .batchLimit(let limit): "This result batch exceeds the supported \(limit)-byte envelope. Previous rows remain available."
        case .pageLimit(let limit): "The result page index reached its \(limit)-page limit. Previous rows remain available."
        case .readLimit: "Request a smaller result viewport. This read exceeds the row or byte limit."
        case .invalidRange: "Result row ranges cannot have negative indices."
        case .corruptSpool: "The temporary result file is incomplete or corrupt."
        case .columnCount(let expected, let actual): "CSV has \(expected) column headers but a stored row has \(actual) values."
        case .io(let message): "Temporary result storage failed: \(message)"
        }
    }
}

/// Defaults represent the entire application's result budget. Divide that budget
/// across worksheet stores; the defaults must not become a per-tab allocation.
/// File access, encoding, decoding, and payload accounting are confined to a serial
/// utility queue. Actor reentrancy never creates concurrent filesystem operations.
public actor ResultStore {
    /// A process-wide quota that allows one active worksheet to use the available
    /// spool space while still limiting the sum across all worksheet stores.
    /// The lock covers integer accounting only; filesystem work never holds it.
    public final class SpoolBudget: @unchecked Sendable {
        public let byteLimit: Int
        private let lock = NSLock()
        private var reservedBytes = 0

        public init(byteLimit: Int = 1_024 * 1_024 * 1_024) { self.byteLimit = max(0, byteLimit) }

        public var usedBytes: Int { lock.withLock { reservedBytes } }

        fileprivate func reserve(_ bytes: Int) -> Bool {
            lock.withLock {
                guard bytes <= byteLimit - reservedBytes else { return false }
                reservedBytes += bytes
                return true
            }
        }

        fileprivate func release(_ bytes: Int) {
            lock.withLock {
                precondition(bytes >= 0 && bytes <= reservedBytes)
                reservedBytes -= bytes
            }
        }
    }

    public struct Configuration: Sendable {
        public let residentByteLimit: Int
        public let spoolByteLimit: Int
        public let sharedSpoolBudget: SpoolBudget?
        public let allowsSpooling: Bool
        public let directory: URL
        public let pageRowLimit: Int
        public let pageByteTarget: Int
        public let maximumBatchBytes: Int
        public let maximumReadRows: Int
        public let maximumReadBytes: Int
        public let maximumPages: Int
        public let maximumPendingOperations: Int

        public init(
            residentByteLimit: Int = 64 * 1_024 * 1_024,
            spoolByteLimit: Int = 1_024 * 1_024 * 1_024,
            sharedSpoolBudget: SpoolBudget? = nil,
            allowsSpooling: Bool = true,
            directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("com.db3.results", isDirectory: true),
            pageRowLimit: Int = 512,
            pageByteTarget: Int = 256 * 1_024,
            maximumBatchBytes: Int = 8 * 1_024 * 1_024,
            maximumReadRows: Int = 4_096,
            maximumReadBytes: Int = 8 * 1_024 * 1_024,
            maximumPages: Int = 65_536,
            maximumPendingOperations: Int = 8
        ) {
            self.residentByteLimit = max(0, residentByteLimit)
            self.spoolByteLimit = max(0, spoolByteLimit)
            self.sharedSpoolBudget = sharedSpoolBudget
            self.allowsSpooling = allowsSpooling
            self.directory = directory
            self.pageRowLimit = max(1, pageRowLimit)
            self.pageByteTarget = max(1, pageByteTarget)
            self.maximumBatchBytes = max(1, maximumBatchBytes)
            self.maximumReadRows = max(1, maximumReadRows)
            self.maximumReadBytes = max(1, maximumReadBytes)
            self.maximumPages = max(1, maximumPages)
            self.maximumPendingOperations = max(1, maximumPendingOperations)
        }
    }

    public struct Statistics: Sendable, Equatable {
        public let rows: Int
        /// Conservative payload accounting, including row/value containers. This is
        /// not the process footprint: index, caller snapshots, and transient I/O count separately.
        public let residentBytes: Int
        public let spooledBytes: Int
        public let pages: Int
        public var rowCount: Int { rows }
    }

    private let storage: Storage
    private let queue = DispatchQueue(label: "com.db3.results.io", qos: .utility)
    private let maximumPendingOperations: Int
    private var pendingOperations = 0
    private var appendPending = false
    private var exportCancellation: CancellationFlag?
    private var isClosed = false
    private var closing: Task<Void, Never>?
    private var latestReceipt: UInt64 = 0
    private var latestStatistics = Statistics(rows: 0, residentBytes: 0, spooledBytes: 0, pages: 0)

    public init(configuration: Configuration = .init()) {
        storage = Storage(configuration: configuration)
        maximumPendingOperations = configuration.maximumPendingOperations
    }

    deinit {
        let storage = storage
        queue.async { storage.close() }
    }

    /// All appends are atomic: cancellation, quota exhaustion, and write errors
    /// preserve every previously accepted row and commit none of the new batch.
    @discardableResult
    public func append(_ batch: RowBatch) async throws -> Int {
        guard !appendPending, exportCancellation == nil else { throw ResultStoreError.busy }
        appendPending = true
        defer { appendPending = false }
        let stats = try await perform { storage, cancellation in
            try storage.append(batch, cancellation: cancellation)
            return storage.statistics
        }
        return stats.rows
    }

    /// Out-of-result upper bounds are clamped, making final partially filled
    /// viewport requests safe. Individual reads have explicit row and byte caps.
    public func rows(in range: Range<Int>) async throws -> [DatabaseRow] {
        try await perform { storage, cancellation in
            try storage.rows(in: range, cancellation: cancellation)
        }
    }

    public func rowCount() -> Int { latestStatistics.rows }
    public func statistics() -> Statistics { latestStatistics }

    /// Writes UTF-8 CSV with CRLF records and a header row. Every text value is
    /// quoted; SQL NULL is an unquoted empty field, while empty text is `""`.
    /// This matches PostgreSQL's default CSV NULL convention. Numeric precision,
    /// embedded newlines, quotes, and Unicode are preserved without conversion.
    ///
    /// Export streams one page plus a 64 KiB encoding buffer. The destination is
    /// atomically replaced only after success; errors/cancellation keep it intact.
    /// Append/reset are rejected during export, and close cancels an active export.
    @discardableResult
    public func exportCSV(columns: [DatabaseColumn], to destination: URL, trailingMetadataColumns: Int = 0) async throws -> Int {
        guard !appendPending, exportCancellation == nil else { throw ResultStoreError.busy }
        let cancellation = CancellationFlag()
        exportCancellation = cancellation
        defer { exportCancellation = nil }
        return try await perform(cancellation: cancellation) { storage, cancellation in
            try storage.exportCSV(columns: columns, to: destination, trailingMetadataColumns: trailingMetadataColumns, cancellation: cancellation)
        }
    }

    public func reset() async throws {
        guard exportCancellation == nil else { throw ResultStoreError.busy }
        try await perform { storage, cancellation in
            try cancellation.check()
            try storage.reset()
        }
    }

    /// Terminal shutdown, ordered after already admitted operations. Best-effort
    /// removal also runs in deinit; unlocked crash remnants are reaped on next use.
    public func close() async {
        if let closing { await closing.value; return }
        isClosed = true
        exportCancellation?.cancel()
        let storage = storage
        let queue = queue
        let task = Task {
            await withCheckedContinuation { continuation in
                queue.async {
                    storage.close()
                    continuation.resume()
                }
            }
        }
        closing = task
        await task.value
        latestStatistics = Statistics(rows: 0, residentBytes: 0, spooledBytes: 0, pages: 0)
    }

    private func perform<T: Sendable>(
        cancellation suppliedCancellation: CancellationFlag? = nil,
        _ operation: @escaping @Sendable (Storage, CancellationFlag) throws -> T
    ) async throws -> T {
        guard !isClosed else { throw ResultStoreError.closed }
        guard pendingOperations < maximumPendingOperations else { throw ResultStoreError.busy }
        try Task.checkCancellation()
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        let cancellation = suppliedCancellation ?? CancellationFlag()
        let storage = storage
        let outcome: OperationOutcome<T> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result: Result<T, any Error>
                    do {
                        try cancellation.check()
                        result = .success(try operation(storage, cancellation))
                    } catch {
                        result = .failure(error)
                    }
                    continuation.resume(returning: OperationOutcome(result: result, receipt: storage.nextReceipt(), statistics: storage.statistics))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        // Queue completion is ordered; actor continuations need not resume in the
        // same order. A receipt prevents an old viewport read reverting newer state.
        if !isClosed && outcome.receipt > latestReceipt {
            latestReceipt = outcome.receipt
            latestStatistics = outcome.statistics
        }
        return try outcome.result.get()
    }
}

private struct OperationOutcome<Value: Sendable>: Sendable {
    let result: Result<Value, any Error>
    let receipt: UInt64
    let statistics: ResultStore.Statistics
}

/// This lock protects only a boolean and is never held over I/O or continuation
/// resumption. Storage itself is queue confined; no UI callback waits on this lock.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// Sendability is justified by exclusive access on ResultStore.queue. Raw file
/// handles and mutable page data never escape that queue.
private final class Storage: @unchecked Sendable {
    private struct Page {
        let firstRow: Int
        let rowCount: Int
        let offset: UInt64
        let encodedBytes: Int
        let residentBytes: Int
    }
    private struct CachedPage {
        let rows: [DatabaseRow]
        var access: UInt64
    }

    let configuration: ResultStore.Configuration
    private var pages: [Page] = []
    private var cache: [Int: CachedPage] = [:]
    private var rowCount = 0
    private var residentBytes = 0
    private var spooledBytes = 0
    private var accessCounter: UInt64 = 0
    private var receipt: UInt64 = 0
    private var file: FileHandle?
    private var spoolDirectory: URL?
    private var leaseDescriptor: Int32 = -1

    init(configuration: ResultStore.Configuration) { self.configuration = configuration }

    func nextReceipt() -> UInt64 { receipt += 1; return receipt }

    var statistics: ResultStore.Statistics {
        .init(rows: rowCount, residentBytes: residentBytes, spooledBytes: spooledBytes, pages: pages.count)
    }

    func append(_ batch: RowBatch, cancellation: CancellationFlag) throws {
        if batch.rows.isEmpty { return }
        var batchBytes = 0
        var costs: [Int] = []
        costs.reserveCapacity(min(batch.rows.count, configuration.maximumBatchBytes / 32))
        for row in batch.rows {
            try cancellation.check()
            let cost = Self.residentCost(row)
            guard cost <= configuration.maximumBatchBytes - batchBytes else {
                throw ResultStoreError.batchLimit(limit: configuration.maximumBatchBytes)
            }
            batchBytes += cost
            costs.append(cost)
        }
        if !configuration.allowsSpooling && batchBytes > configuration.residentByteLimit - residentBytes {
            throw ResultStoreError.memoryLimit(limit: configuration.residentByteLimit)
        }

        // Index and payload remain private until the entire batch has been written.
        var staged: [(page: Page, rows: [DatabaseRow])] = []
        var stagedSpoolBytes = 0
        var reservedSpoolBytes = 0
        var first = 0
        do {
            while first < batch.rows.count {
                try cancellation.check()
                guard pages.count + staged.count < configuration.maximumPages else {
                    throw ResultStoreError.pageLimit(limit: configuration.maximumPages)
                }
                var end = first
                var pageBytes = 0
                while end < batch.rows.count && end - first < configuration.pageRowLimit {
                    if end > first && costs[end] > configuration.pageByteTarget - pageBytes { break }
                    pageBytes += costs[end]
                    end += 1
                    if pageBytes >= configuration.pageByteTarget { break }
                }
                let rows = Array(batch.rows[first..<end])
                let offset = UInt64(spooledBytes + stagedSpoolBytes)
                var encodedBytes = 0
                if configuration.allowsSpooling {
                    let encoded = try PageCodec.encode(rows)
                    try cancellation.check()
                    guard encoded.count <= configuration.spoolByteLimit - spooledBytes - stagedSpoolBytes else {
                        throw ResultStoreError.spoolQuota(limit: configuration.spoolByteLimit)
                    }
                    if let budget = configuration.sharedSpoolBudget {
                        guard budget.reserve(encoded.count) else { throw ResultStoreError.spoolQuota(limit: budget.byteLimit) }
                        reservedSpoolBytes += encoded.count
                    }
                    try openSpoolIfNeeded()
                    try file?.seek(toOffset: offset)
                    try file?.write(contentsOf: encoded)
                    encodedBytes = encoded.count
                    stagedSpoolBytes += encodedBytes
                }
                staged.append((Page(firstRow: rowCount + first, rowCount: end - first, offset: offset,
                                    encodedBytes: encodedBytes, residentBytes: pageBytes), rows))
                first = end
            }
            try cancellation.check()
        } catch {
            configuration.sharedSpoolBudget?.release(reservedSpoolBytes)
            // A failed truncate leaves old index entries intact and readable. A
            // later write seeks to the last committed offset and overwrites tail data.
            try? file?.truncate(atOffset: UInt64(spooledBytes))
            throw Self.storageError(error)
        }
        for item in staged {
            pages.append(item.page)
            insertCache(item.rows, index: pages.count - 1)
        }
        rowCount += batch.rows.count
        spooledBytes += stagedSpoolBytes
    }

    func rows(in requested: Range<Int>, cancellation: CancellationFlag) throws -> [DatabaseRow] {
        guard requested.lowerBound >= 0 else { throw ResultStoreError.invalidRange }
        let lower = min(requested.lowerBound, rowCount)
        let upper = min(requested.upperBound, rowCount)
        guard upper - lower <= configuration.maximumReadRows else { throw ResultStoreError.readLimit }
        if lower == upper { return [] }
        var result: [DatabaseRow] = []
        result.reserveCapacity(upper - lower)
        var resultBytes = 0

        // Binary search keeps viewport lookup independent of the total row count.
        var left = 0
        var right = pages.count
        while left < right {
            let middle = left + (right - left) / 2
            if pages[middle].firstRow + pages[middle].rowCount <= lower { left = middle + 1 }
            else { right = middle }
        }
        var index = left
        do {
            while index < pages.count && pages[index].firstRow < upper {
                try cancellation.check()
                let page = pages[index]
                let pageRows = try loadPage(at: index)
                let start = max(lower, page.firstRow) - page.firstRow
                let end = min(upper, page.firstRow + page.rowCount) - page.firstRow
                for row in pageRows[start..<end] {
                    let bytes = Self.residentCost(row)
                    guard bytes <= configuration.maximumReadBytes - resultBytes else { throw ResultStoreError.readLimit }
                    resultBytes += bytes
                    result.append(row)
                }
                index += 1
            }
            try cancellation.check()
            return result
        } catch { throw Self.storageError(error) }
    }

    func exportCSV(columns: [DatabaseColumn], to destination: URL, trailingMetadataColumns: Int, cancellation: CancellationFlag) throws -> Int {
        guard (0...1).contains(trailingMetadataColumns) else { throw ResultStoreError.columnCount(expected: columns.count, actual: trailingMetadataColumns) }
        guard destination.isFileURL, !destination.path.utf8.contains(0) else {
            throw ResultStoreError.io("Choose a local file for CSV export.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".db3-export-" + UUID().uuidString + ".tmp")
        try cancellation.check()
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ResultStoreError.io(String(cString: strerror(errno))) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            var writer = CSVWriter(output: output, cancellation: cancellation)
            for (index, column) in columns.enumerated() {
                if index > 0 { try writer.append(0x2C) }
                try writer.quoted(column.name)
            }
            try writer.endRecord()
            var exportedRows = 0
            for index in pages.indices {
                try cancellation.check()
                // Avoid replacing the user's viewport cache with an export scan.
                let rows = try loadPage(at: index, cacheResult: false)
                for row in rows {
                    try cancellation.check()
                    guard row.count == columns.count + trailingMetadataColumns else {
                        throw ResultStoreError.columnCount(expected: columns.count, actual: row.count)
                    }
                    for (index, value) in row.prefix(columns.count).enumerated() {
                        if index > 0 { try writer.append(0x2C) }
                        if case .text(let text) = value { try writer.quoted(text) }
                    }
                    try writer.endRecord()
                    exportedRows += 1
                }
            }
            try writer.flush()
            try cancellation.check()
            try output.synchronize()
            try output.close()
            try cancellation.check()
            // The adjacent temporary file guarantees same-filesystem atomic rename.
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw ResultStoreError.io(String(cString: strerror(errno)))
            }
            return exportedRows
        } catch { throw Self.storageError(error) }
    }

    private func loadPage(at index: Int, cacheResult: Bool = true) throws -> [DatabaseRow] {
        let page = pages[index]
        if var cached = cache[index] {
            if cacheResult {
                accessCounter &+= 1
                cached.access = accessCounter
                cache[index] = cached
            }
            return cached.rows
        }
        guard let file else { throw ResultStoreError.corruptSpool }
        try file.seek(toOffset: page.offset)
        guard let data = try file.read(upToCount: page.encodedBytes), data.count == page.encodedBytes else {
            throw ResultStoreError.corruptSpool
        }
        let rows = try PageCodec.decode(data)
        guard rows.count == page.rowCount else { throw ResultStoreError.corruptSpool }
        if cacheResult { insertCache(rows, index: index) }
        return rows
    }

    func reset() throws {
        // Delete before clearing the published index so cleanup failures are visible.
        if let directory = spoolDirectory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw Self.storageError(error) }
        }
        closeHandles()
        clear()
    }

    func close() {
        if let directory = spoolDirectory { try? FileManager.default.removeItem(at: directory) }
        closeHandles()
        clear()
    }

    private func clear() {
        configuration.sharedSpoolBudget?.release(spooledBytes)
        pages.removeAll(keepingCapacity: false)
        cache.removeAll(keepingCapacity: false)
        rowCount = 0
        residentBytes = 0
        spooledBytes = 0
        accessCounter = 0
        spoolDirectory = nil
    }

    private func closeHandles() {
        try? file?.close()
        file = nil
        if leaseDescriptor >= 0 {
            Darwin.close(leaseDescriptor)
            leaseDescriptor = -1
        }
    }

    private func insertCache(_ rows: [DatabaseRow], index: Int) {
        let cost = pages[index].residentBytes
        guard cost <= configuration.residentByteLimit else { return }
        while residentBytes > configuration.residentByteLimit - cost {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key else { break }
            residentBytes -= pages[oldest].residentBytes
            cache.removeValue(forKey: oldest)
        }
        accessCounter &+= 1
        cache[index] = CachedPage(rows: rows, access: accessCounter)
        residentBytes += cost
    }

    private func openSpoolIfNeeded() throws {
        guard file == nil else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: configuration.directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        Self.removeAbandonedSpools(in: configuration.directory)
        let identifier = UUID().uuidString
        // Publish the directory under the reaper's prefix only after holding its
        // lease. Other stores cannot reap a newly created but not-yet-locked file.
        let directory = configuration.directory.appendingPathComponent("building-" + identifier, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let lease = directory.appendingPathComponent("lease")
            leaseDescriptor = Darwin.open(lease.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
            guard leaseDescriptor >= 0, flock(leaseDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw ResultStoreError.io("Cannot acquire the temporary result lease.")
            }
            let dataURL = directory.appendingPathComponent("pages.bin")
            guard manager.createFile(atPath: dataURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ResultStoreError.io("Cannot create the temporary result file.")
            }
            file = try FileHandle(forUpdating: dataURL)
            let published = configuration.directory.appendingPathComponent("result-" + identifier, isDirectory: true)
            try manager.moveItem(at: directory, to: published)
            spoolDirectory = published
        } catch {
            closeHandles()
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func removeAbandonedSpools(in root: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("result-") {
            guard let info = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  info.isDirectory == true, info.isSymbolicLink != true else { continue }
            let descriptor = Darwin.open(entry.appendingPathComponent("lease").path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            // Only remove directories whose lease is no longer owned by any store.
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { try? manager.removeItem(at: entry) }
            Darwin.close(descriptor)
        }
    }

    private static func residentCost(_ row: DatabaseRow) -> Int {
        row.reduce(32) { partial, value in
            switch value { case .null: partial + 32; case .text(let text): partial + 32 + text.utf8.count }
        }
    }

    private static func storageError(_ error: any Error) -> any Error {
        if error is ResultStoreError || error is CancellationError { return error }
        return ResultStoreError.io(error.localizedDescription)
    }
}

/// Encodes directly into bounded output chunks, including oversized individual
/// fields. Quoting does not construct a second full-sized String or Data value.
private struct CSVWriter {
    let output: FileHandle
    let cancellation: CancellationFlag
    private var buffer = Data()
    private let capacity = 64 * 1_024

    init(output: FileHandle, cancellation: CancellationFlag) {
        self.output = output
        self.cancellation = cancellation
        buffer.reserveCapacity(capacity)
    }

    mutating func append(_ byte: UInt8) throws {
        buffer.append(byte)
        if buffer.count >= capacity { try flush() }
    }

    mutating func quoted(_ text: String) throws {
        try append(0x22)
        for byte in text.utf8 {
            try append(byte)
            if byte == 0x22 { try append(0x22) }
        }
        try append(0x22)
    }

    mutating func endRecord() throws { try append(0x0D); try append(0x0A) }

    mutating func flush() throws {
        try cancellation.check()
        if !buffer.isEmpty {
            try output.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

/// Compact, versioned temporary format. PostgreSQL values remain exact UTF-8
/// strings; the reserved length sentinel distinguishes SQL NULL from empty text.
private enum PageCodec {
    static func encode(_ rows: [DatabaseRow]) throws -> Data {
        var data = Data([0x44, 0x42, 0x33, 1])
        guard let rowCount = UInt32(exactly: rows.count) else { throw ResultStoreError.corruptSpool }
        append(rowCount, to: &data)
        for row in rows {
            guard let columnCount = UInt32(exactly: row.count) else { throw ResultStoreError.corruptSpool }
            append(columnCount, to: &data)
            for value in row {
                switch value {
                case .null: append(UInt64.max, to: &data)
                case .text(let text):
                    append(UInt64(text.utf8.count), to: &data)
                    data.append(contentsOf: text.utf8)
                }
            }
        }
        return data
    }

    static func decode(_ data: Data) throws -> [DatabaseRow] {
        guard data.count >= 8, data.prefix(4) == Data([0x44, 0x42, 0x33, 1]) else { throw ResultStoreError.corruptSpool }
        var cursor = 4
        let rowCount: UInt32 = try read(data, cursor: &cursor)
        guard Int(rowCount) <= (data.count - cursor) / 4 else { throw ResultStoreError.corruptSpool }
        var rows: [DatabaseRow] = []
        rows.reserveCapacity(Int(rowCount))
        for _ in 0..<rowCount {
            let columns: UInt32 = try read(data, cursor: &cursor)
            guard Int(columns) <= (data.count - cursor) / 8 else { throw ResultStoreError.corruptSpool }
            var row: DatabaseRow = []
            row.reserveCapacity(Int(columns))
            for _ in 0..<columns {
                let length: UInt64 = try read(data, cursor: &cursor)
                if length == UInt64.max { row.append(.null); continue }
                guard length <= UInt64(data.count - cursor) else { throw ResultStoreError.corruptSpool }
                let end = cursor + Int(length)
                guard let text = String(data: data[cursor..<end], encoding: .utf8) else { throw ResultStoreError.corruptSpool }
                row.append(.text(text))
                cursor = end
            }
            rows.append(row)
        }
        guard cursor == data.count else { throw ResultStoreError.corruptSpool }
        return rows
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ data: Data, cursor: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard cursor <= data.count - size else { throw ResultStoreError.corruptSpool }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: T.self) }
        cursor += size
        return T(littleEndian: value)
    }
}
