import Foundation
import XCTest
import DB3Core

final class SQLDirectTableSelectTests: XCTestCase {
    func testOneNamedSourceWithSupportedClausesAndAliases() throws {
        let statements = [
            "SELECT * FROM records",
            "select id, title from public.records r where r.id = 2 order by r.id desc limit 100 offset 2;",
            "SELECT ALL r.* FROM ONLY public.records AS r FOR UPDATE OF r SKIP LOCKED",
            "SELECT DISTINCT id, title FROM records OFFSET 2 ROWS FETCH NEXT 10 ROWS ONLY",
            "SELECT id FROM records ORDER BY id FETCH FIRST 5 ROWS WITH TIES",
            "SELECT id FROM records FOR NO KEY UPDATE NOWAIT LIMIT 3",
            #"SELECT "alias"."id" FROM "Sales.EU"."Order""Items" AS "alias" WHERE "alias"."title" = 'JOIN x; SELECT y'"#,
            #"SELECT "JOIN"."id" FROM "FROM" AS "JOIN" ORDER BY "JOIN"."id""#,
            "/* SELECT misleading FROM wrong /* nested */ */ SELECT id -- FROM hidden\nFROM records; -- trailing JOIN wrong",
            "SELECT COALESCE(title, 'FROM hidden'), extract(year FROM created_at) FROM records WHERE length(title) > 1",
            #"SELECT E'it\'s; FROM wrong JOIN other' AS note, id FROM records"#,
            "SELECT $body$ ) ; SELECT * FROM wrong JOIN other $body$, id FROM records",
            "SELECT $$' FROM wrong;$$, id FROM records WHERE title = $🐘$JOIN x$🐘$",
            "SELECT id FROM records WHERE (id > 2 AND (title = 'x' OR title = 'y')) ORDER BY id, title",
            "SELECT id FROM records WHERE title = 'a''; SELECT * FROM wrong'"
        ]
        for sql in statements { XCTAssertTrue(try SQLDirectTableSelect.isEligible(sql), sql) }
    }

    func testAmbiguousOrMultipleSourcesAndUnsupportedQueryShapesAreRejected() throws {
        let statements = [
            "SELECT a.id, b.title FROM records a JOIN records b ON a.id != b.id",
            "SELECT a.id, b.title FROM records a, records b",
            "SELECT a.* FROM records a LEFT /* hidden */ JOIN other b USING (id)",
            "SELECT * FROM records NATURAL JOIN other",
            "SELECT * FROM records CROSS JOIN LATERAL some_function()",
            "SELECT * FROM generate_series(1, 4)",
            "SELECT * FROM public.records() AS r",
            "SELECT * FROM (records)",
            "SELECT * FROM ONLY (records)",
            "SELECT * FROM records AS r(id, title)",
            "SELECT * FROM records TABLESAMPLE SYSTEM (10)",
            "SELECT * FROM (SELECT * FROM records) r",
            "WITH source AS (SELECT * FROM records) SELECT * FROM source",
            "SELECT id, (SELECT title FROM records b WHERE b.id = 2) FROM records a",
            "SELECT * FROM records WHERE EXISTS (SELECT 1 FROM other)",
            "SELECT * FROM records WHERE id IN (WITH source AS (VALUES (1)) TABLE source)",
            "SELECT id FROM records UNION SELECT id FROM records",
            "SELECT id FROM records INTERSECT SELECT id FROM records",
            "SELECT id FROM records EXCEPT SELECT id FROM records",
            "SELECT id FROM records GROUP BY id",
            "SELECT id FROM records HAVING count(*) > 1",
            "SELECT id FROM records WINDOW w AS ()",
            "SELECT * INTO copied_records FROM records",
            "SELECT * FROM records; DELETE FROM records",
            "SELECT * FROM records; SELECT * FROM records",
            "SELECT * FROM records ORDER BY id; COMMIT;",
            "SELECT * FROM records FROM other",
            "SELECT * FROM first.second.third",
            "SELECT 1", "TABLE records", "VALUES (1)", "DELETE FROM records RETURNING *"
        ]
        for sql in statements { XCTAssertFalse(try SQLDirectTableSelect.isEligible(sql), sql) }
    }

    func testQuotesCommentsAndDollarBodiesCannotConcealAnotherSource() throws {
        let statements = [
            #"SELECT 'JOIN x', a.id, b.title FROM records a JOIN records b ON true"#,
            "SELECT $$ JOIN hidden $$, a.id FROM records a, records b",
            "SELECT id FROM records /* closed */ JOIN other USING (id)",
            "SELECT id FROM records -- ignored\nJOIN other USING (id)",
            #"SELECT "JOIN" FROM records, other"#,
            #"SELECT E'\' JOIN text' FROM records JOIN other ON true"#,
            "SELECT $tag$FROM other$tag$ FROM records; SELECT 1",
            #"SELECT 'it\'s ambiguous' FROM records"#
        ]
        for sql in statements { XCTAssertFalse(try SQLDirectTableSelect.isEligible(sql), sql) }
    }

    func testIncompleteSyntaxFailsClosed() throws {
        for sql in ["", "-- comment", "SELECT FROM records", "SELECT * FROM", "SELECT * FROM public.",
                    "SELECT * FROM records AS", "SELECT * FROM records WHERE", "SELECT * FROM records ORDER BY",
                    "SELECT * FROM records LIMIT", "SELECT * FROM records WHERE (id > 0", "SELECT * FROM records WHERE id > 0)",
                    "SELECT 'unfinished FROM records", "SELECT * FROM \"unfinished", "SELECT $$unfinished FROM records",
                    "SELECT * FROM records /* unfinished", "SELECT * FROM records ORDER title", "SELECT * FROM records LIMIT 1 LIMIT 2",
                    "SELECT * FROM records LIMIT 1 FETCH FIRST 2 ROWS ONLY", "SELECT * FROM records WHERE (id = 1;)",
                    "SELECT * FROM records -- bad\0comment", "SELECT '\0' FROM records"] {
            XCTAssertFalse(try SQLDirectTableSelect.isEligible(sql), sql)
        }
    }

    func testCancellationPropagatesInsteadOfMakingAnEligibilityDecision() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SQLDirectTableSelect.isEligible("SELECT * FROM records")
        }
        do { _ = try await task.value; XCTFail("Canceled inspection must stop.") }
        catch is CancellationError { }
    }
}
