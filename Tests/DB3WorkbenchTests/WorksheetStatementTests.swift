import Foundation
import XCTest
import DB3Core
@testable import DB3Workbench

/// Run uses the real worksheet pipeline and an isolated recording session. No
/// browser, native window, Keychain, or PostgreSQL connection is opened.
@MainActor
final class WorksheetStatementTests: XCTestCase {
    func testRunExecutesOnlyStatementAtSecondCaret() async throws {
        let fixture = try await connectedFixture()
        let sheet = fixture.model.active
        sheet.sql = "SELECT 'first';\nSELECT '🐘 second';\nSELECT 'third';"
        sheet.selection = caret(in: sheet.sql, at: "second")
        sheet.run()
        try await eventually { !sheet.isBusy }
        let queries = await fixture.sessions[0].queries
        let rows = try await sheet.store.rows(in: 0..<sheet.rowCount)
        XCTAssertEqual(queries, ["\nSELECT '🐘 second';"])
        XCTAssertEqual(rows, [[.text("\nSELECT '🐘 second';")]])
        XCTAssertEqual(sheet.status, "Complete")
        await fixture.model.shutdown()
    }

    func testHighlightedFragmentTakesPriorityAndIsNotRewritten() async throws {
        let fixture = try await connectedFixture()
        let sheet = fixture.model.active
        let fragment = "  SELECT 'selected; value'  "
        sheet.sql = "SELECT 'before';\n" + fragment + ";\nSELECT 'after';"
        sheet.selection = (sheet.sql as NSString).range(of: fragment)
        sheet.run()
        try await eventually { !sheet.isBusy }
        let queries = await fixture.sessions[0].queries
        XCTAssertEqual(queries, [fragment])
        await fixture.model.shutdown()
    }

    func testTransactionOverrideIgnoresDocumentAndInvalidSelection() async throws {
        let fixture = try await connectedFixture()
        let sheet = fixture.model.active
        sheet.sql = "SELECT 'do not execute'; SELECT 'also ignored';"
        sheet.selection = NSRange(location: NSNotFound, length: 0)
        sheet.run(sql: "BEGIN")
        try await eventually { !sheet.isBusy }
        let queries = await fixture.sessions[0].queries
        XCTAssertEqual(queries, ["BEGIN"])
        XCTAssertNil(sheet.error)
        await fixture.model.shutdown()
    }

    func testInvalidSelectionDoesNotExecuteOrReplacePreviousResults() async throws {
        let fixture = try await connectedFixture()
        let sheet = fixture.model.active
        try await seedResult(in: sheet)
        let previousStore = sheet.store
        let previousColumns = sheet.columns
        let previousRevision = sheet.revision
        sheet.sql = "SELECT 'must not execute';"
        sheet.selection = NSRange(location: 3, length: Int.max)
        sheet.run()
        try await eventually { !sheet.isBusy }
        let queries = await fixture.sessions[0].queries
        let rows = try await sheet.store.rows(in: 0..<sheet.rowCount)
        XCTAssertEqual(queries, ["SELECT 'existing result';"])
        XCTAssertTrue(sheet.store === previousStore)
        XCTAssertEqual(sheet.columns, previousColumns)
        XCTAssertEqual(sheet.revision, previousRevision)
        XCTAssertEqual(rows, [[.text("SELECT 'existing result';")]])
        XCTAssertEqual(sheet.rowCount, 1)
        XCTAssertFalse(sheet.resultIncomplete)
        XCTAssertTrue(sheet.error?.contains("selection") == true)
        await fixture.model.shutdown()
    }

    func testCommentsOnlySelectionDoesNotExecuteOrReplacePreviousResults() async throws {
        let fixture = try await connectedFixture()
        let sheet = fixture.model.active
        try await seedResult(in: sheet)
        let previousStore = sheet.store
        let previousRevision = sheet.revision
        let comment = "/* selected comment; /* nested */ */"
        sheet.sql = "SELECT 'must not execute';\n" + comment
        sheet.selection = (sheet.sql as NSString).range(of: comment)
        sheet.run()
        try await eventually { !sheet.isBusy }
        let queries = await fixture.sessions[0].queries
        let rows = try await sheet.store.rows(in: 0..<sheet.rowCount)
        XCTAssertEqual(queries, ["SELECT 'existing result';"])
        XCTAssertTrue(sheet.store === previousStore)
        XCTAssertEqual(sheet.revision, previousRevision)
        XCTAssertEqual(rows, [[.text("SELECT 'existing result';")]])
        XCTAssertEqual(sheet.rowCount, 1)
        XCTAssertFalse(sheet.resultIncomplete)
        XCTAssertNil(sheet.error)
        XCTAssertEqual(sheet.status, "No SQL statement")
        await fixture.model.shutdown()
    }

    func testRunCapturesOriginalTabDocumentAndSelectionBeforeSwitching() async throws {
        let fixture = try await connectedFixture()
        let model = fixture.model
        let first = model.active
        model.addWorksheet()
        let second = model.active
        second.connect(ConnectionProfile(name: "Second", database: "second"), password: "")
        try await eventually { second.isConnected && !second.isBusy }
        second.sql = "SELECT 'other tab';"
        first.sql = "SELECT 'first statement';\nSELECT 'captured statement';"
        first.selection = caret(in: first.sql, at: "captured")
        model.selectTab(first.id)
        model.active.run()
        // These changes occur before the async run task can resume on MainActor.
        first.sql = "SELECT 'later edit';"
        first.selection = NSRange(location: 0, length: first.sql.utf16.count)
        model.selectTab(second.id)
        try await eventually { !first.isBusy }
        let firstQueries = await fixture.sessions[0].queries
        let secondQueries = await fixture.sessions[1].queries
        XCTAssertEqual(firstQueries, ["\nSELECT 'captured statement';"])
        XCTAssertTrue(secondQueries.isEmpty)
        XCTAssertTrue(model.active === second)
        XCTAssertEqual(first.sql, "SELECT 'later edit';")
        XCTAssertEqual(second.sql, "SELECT 'other tab';")
        XCTAssertEqual(first.rowCount, 1)
        XCTAssertEqual(second.rowCount, 0)
        await model.shutdown()
    }

    func testImmediateCancelDuringPreparationPreservesPreviousResults() async throws {
        let fixture = try await connectedFixture()
        let sheet = fixture.model.active
        try await seedResult(in: sheet)
        let previousStore = sheet.store
        let previousRevision = sheet.revision
        sheet.sql = "SELECT 'never sent';"
        sheet.selection = NSRange(location: 0, length: 0)
        sheet.run()
        sheet.cancel()
        try await eventually { !sheet.isBusy }
        let queries = await fixture.sessions[0].queries
        let cancelCount = await fixture.sessions[0].cancelCount
        XCTAssertEqual(queries, ["SELECT 'existing result';"])
        XCTAssertEqual(cancelCount, 0)
        XCTAssertTrue(sheet.store === previousStore)
        XCTAssertEqual(sheet.revision, previousRevision)
        XCTAssertEqual(sheet.rowCount, 1)
        XCTAssertEqual(sheet.status, "Cancelled")
        XCTAssertFalse(sheet.isCancelling)
        await fixture.model.shutdown()
    }

    func testClosingDuringPreparationDoesNotSendSQLOrReviveWorksheet() async throws {
        let fixture = try await connectedFixture()
        let sheet = fixture.model.active
        sheet.sql = "SELECT 'never sent';"
        sheet.run()
        sheet.prepareToClose()
        await sheet.close()
        // Let both the cancelled detached parser and its awaiting task settle.
        try await Task.sleep(for: .milliseconds(20))
        let queries = await fixture.sessions[0].queries
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(sheet.isClosed)
        XCTAssertFalse(sheet.isBusy)
        XCTAssertFalse(sheet.isConnected)
        XCTAssertEqual(sheet.rowCount, 0)
        XCTAssertNil(sheet.error)
        await fixture.model.shutdown()
    }

    private func connectedFixture() async throws -> WorkbenchFixture {
        let fixture = WorkbenchFixture()
        let sheet = fixture.model.active
        sheet.connect(ConnectionProfile(name: "Statement tests"), password: "")
        try await eventually { sheet.isConnected && !sheet.isBusy }
        return fixture
    }

    private func seedResult(in sheet: Worksheet) async throws {
        sheet.sql = "SELECT 'existing result';"
        sheet.selection = NSRange(location: 0, length: 0)
        sheet.run()
        try await eventually { !sheet.isBusy && sheet.rowCount == 1 }
    }

    private func caret(in sql: String, at text: String) -> NSRange {
        NSRange(location: (sql as NSString).range(of: text).location, length: 0)
    }

    private func eventually(_ predicate: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Worksheet work did not reach its expected state", file: file, line: line)
        throw DatabaseError("Timed out waiting for worksheet work")
    }
}
