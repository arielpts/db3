import Foundation
import XCTest
import DB3Core

final class SQLStatementSelectionTests: XCTestCase {
    private func at(_ sql: String, _ needle: String, offset: Int = 0) throws -> String? {
        let location = (sql as NSString).range(of: needle).location
        XCTAssertNotEqual(location, NSNotFound)
        return try SQLStatementSelection.statement(in: sql, selection: NSRange(location: location + offset, length: 0))
    }

    func testCaretSelectsSecondStatement() throws {
        let sql = "SELECT 1;\nSELECT * FROM customers;\nSELECT 3;"
        XCTAssertEqual(try at(sql, "customers"), "\nSELECT * FROM customers;")
    }

    func testExplicitHighlightIsExactAndMayContainMultipleStatements() throws {
        let sql = "SELECT 0;\n  SELECT 1; SELECT 2;  \nSELECT 3;"
        let selected = "  SELECT 1; SELECT 2;  "
        XCTAssertEqual(try SQLStatementSelection.statement(in: sql, selection: (sql as NSString).range(of: selected)), selected)
    }

    func testCaretAndHighlightUseUTF16Offsets() throws {
        let sql = "SELECT '🐘 café';\nSELECT 'ação 🦊';"
        XCTAssertEqual(try at(sql, "ação"), "\nSELECT 'ação 🦊';")
        let selected = "SELECT 'ação 🦊'"
        XCTAssertEqual(try SQLStatementSelection.statement(in: sql, selection: (sql as NSString).range(of: selected)), selected)
    }

    func testInvalidRangesFailClosed() throws {
        let sql = "SELECT '🐘';"
        let elephant = (sql as NSString).range(of: "🐘").location
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: 0),
                      NSRange(location: 0, length: -1), NSRange(location: 2, length: Int.max),
                      NSRange(location: 100, length: 0), NSRange(location: elephant + 1, length: 0),
                      NSRange(location: elephant, length: 1)] {
            XCTAssertThrowsError(try SQLStatementSelection.statement(in: sql, selection: range)) {
                XCTAssertTrue($0 is DatabaseError)
            }
        }
    }

    func testSemicolonBelongsToLeftAndInterstatementWhitespaceToRight() throws {
        let sql = "SELECT 1; \n\tSELECT 2;   "
        XCTAssertEqual(try at(sql, ";"), "SELECT 1;")
        XCTAssertEqual(try at(sql, " \n"), " \n\tSELECT 2;")
        XCTAssertEqual(try SQLStatementSelection.statement(in: sql, selection: NSRange(location: sql.utf16.count, length: 0)), " \n\tSELECT 2;")
    }

    func testEmptyDocumentsAndCommentsOnlyHaveNoStatement() throws {
        for sql in ["", " \t\r\n", ";; ;", "-- SELECT 1;\n", "/* outer ; /* nested ; */ done */"] {
            XCTAssertNil(try SQLStatementSelection.statement(in: sql, selection: NSRange(location: sql.utf16.count, length: 0)))
            if !sql.isEmpty {
                XCTAssertNil(try SQLStatementSelection.statement(in: sql, selection: NSRange(location: 0, length: sql.utf16.count)))
            }
        }
    }

    func testQuotesAndDoubledQuotesDoNotSplitStatements() throws {
        let first = #"SELECT 'a;b'';c', "a;b"";c", U&'d\0061;t';"#
        let sql = first + "\nSELECT 2;"
        XCTAssertEqual(try at(sql, "b''"), first)
        XCTAssertEqual(try at(sql, "SELECT 2"), "\nSELECT 2;")
    }

    func testEscapeStringsAndContinuationDoNotSplitStatements() throws {
        let first = #"SELECT E'can\'t;stop'"# + "\n" + #"'keep\'going;';"#
        let sql = first + " SELECT 2;"
        XCTAssertEqual(try at(sql, "going"), first)
        XCTAssertEqual(try at(sql, "SELECT 2"), " SELECT 2;")
    }

    func testNestedAndLineCommentsDoNotSplitStatements() throws {
        let first = "/* outer; /* inner; */ end */ SELECT 1 -- ignored;\n;"
        let second = "\n-- description;\nSELECT 2;"
        let sql = first + second + "\n-- trailing comment;"
        XCTAssertEqual(try at(sql, "inner"), first)
        XCTAssertEqual(try at(sql, "description"), second)
        XCTAssertEqual(try at(sql, "trailing"), second)
    }

    func testDollarQuotedFunctionAndCaseSensitiveTags() throws {
        let function = "CREATE FUNCTION f() RETURNS void AS $body$ BEGIN PERFORM ';'; RAISE NOTICE $$inner;$$; END; $BODY$; $body$ LANGUAGE plpgsql;"
        let sql = function + "\nSELECT f();"
        XCTAssertEqual(try at(sql, "PERFORM"), function)
        XCTAssertEqual(try at(sql, "SELECT f"), "\nSELECT f();")
        XCTAssertEqual(try at("SELECT $é$semi;colon$é$; SELECT 2;", "semi"), "SELECT $é$semi;colon$é$;")
    }

    func testDollarWithinIdentifierIsNotAQuote() throws {
        let sql = "SELECT foo$tag$; SELECT 2;"
        XCTAssertEqual(try at(sql, "foo"), "SELECT foo$tag$;")
        XCTAssertEqual(try at(sql, "SELECT 2"), " SELECT 2;")
    }

    func testBeginAtomicRequiresExplicitSelection() throws {
        let function = "CREATE FUNCTION f() RETURNS integer LANGUAGE SQL BEGIN /* nested */ ATOMIC SELECT 1; SELECT 2; END;"
        XCTAssertThrowsError(try at(function, "SELECT 2")) {
            XCTAssertTrue($0.localizedDescription.contains("BEGIN ATOMIC"))
        }
        XCTAssertEqual(try SQLStatementSelection.statement(in: function, selection: NSRange(location: 0, length: function.utf16.count)), function)
        XCTAssertEqual(try at("BEGIN; SELECT 1; COMMIT;", "SELECT 1"), " SELECT 1;")
    }

    func testCreateRuleActionsRemainOneStatement() throws {
        let rule = "CREATE RULE audit AS ON INSERT TO customers DO ALSO (INSERT INTO audit_log VALUES (NEW.id); UPDATE totals SET amount = (amount + 1););"
        let sql = rule + "\nSELECT 2;"
        XCTAssertEqual(try at(sql, "UPDATE totals"), rule)
        XCTAssertEqual(try at(sql, "SELECT 2"), "\nSELECT 2;")
    }

    func testUnterminatedSyntaxAndAmbiguousBackslashFailClosed() throws {
        for sql in ["SELECT 'unfinished; SELECT 2;", "SELECT \"unfinished;", "DO $body$ BEGIN;", "/* unfinished", #"SELECT 'ambiguous\'; SELECT 2;"#, "SELECT (1; SELECT 2;", "SELECT 1); SELECT 2;"] {
            XCTAssertThrowsError(try SQLStatementSelection.statement(in: sql, selection: NSRange(location: sql.utf16.count, length: 0))) {
                XCTAssertTrue($0 is DatabaseError)
            }
        }
    }

    func testManyStatementsNeedOnlyTheChosenRange() throws {
        let sql = String(repeating: "SELECT '🐘;';\n", count: 20_000) + "SELECT 'last';"
        XCTAssertEqual(try at(sql, "last"), "\nSELECT 'last';")
    }

    func testCancellationIsObserved() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SQLStatementSelection.statement(in: String(repeating: "SELECT 1;", count: 10_000), selection: NSRange(location: 0, length: 0))
        }
        do { _ = try await task.value; XCTFail("Cancelled selection must not return executable SQL.") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
