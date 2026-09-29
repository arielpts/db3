import XCTest
import DB3Core

final class ValueChoiceTests: XCTestCase {
    func testCanonicallyEquivalentUnicodeKeysRemainDistinctDatabaseValues() throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift normalizes String equality; PostgreSQL enum keys do not.")
        XCTAssertNotEqual(DatabaseValue.text(composed), DatabaseValue.text(decomposed))
        XCTAssertEqual(Set([DatabaseValue.text(composed), .text(decomposed)]).count, 2)
        let choices = try ValueChoiceSet(choices: [.init(key: composed, label: "First"), .init(key: decomposed, label: "Second")], source: "PostgreSQL", revision: "1", origin: .postgresEnum(typeOID: 100))
        XCTAssertEqual(choices.choices.count, 2)
        let onlyComposed = try ValueChoiceSet(choices: [.init(key: composed, label: "First")], source: "S", revision: "1")
        XCTAssertTrue(onlyComposed.contains(key: composed)); XCTAssertFalse(onlyComposed.contains(key: decomposed))
    }
    func testSearchVisitsBeyondRenderedLimitAndMatchesLiteralKeyLabelDescription() throws {
        var entries = (0..<900).map { ValueChoice(key: "key_\($0)", label: "Label \($0)") }
        entries.append(ValueChoice(key: "exact%_\\", label: "Final LABEL", description: "Hidden Zebra 🐘"))
        let choices = try ValueChoiceSet(choices: entries, source: "Synthetic source", revision: "1")
        let all = try choices.search("")
        XCTAssertEqual(all.indices.count, 200); XCTAssertEqual(all.totalMatches, 901); XCTAssertTrue(all.isLimited)
        XCTAssertEqual(try choices.search("zEBRa").indices, [900])
        XCTAssertEqual(try choices.search("FINAL label").indices, [900])
        XCTAssertEqual(try choices.search("%_\\").indices, [900], "Search punctuation is literal, not LIKE or regex syntax.")
        XCTAssertEqual(try choices.search("🐘").indices, [900])
    }

    func testFingerprintsIncludeMeaningEvenWhenProviderRevisionIsUnchanged() throws {
        let first = try ValueChoiceSet(choices: [.init(key: "a", label: "First")], source: "Source", revision: "same")
        let renamed = try ValueChoiceSet(choices: [.init(key: "a", label: "Renamed")], source: "Source", revision: "same")
        let described = try ValueChoiceSet(choices: [.init(key: "a", label: "First", description: "New meaning")], source: "Source", revision: "same")
        XCTAssertNotEqual(first.fingerprint, renamed.fingerprint); XCTAssertNotEqual(first.fingerprint, described.fingerprint)
        XCTAssertEqual(first.fingerprint, try ValueChoiceSet(choices: first.choices, source: first.source, revision: first.revision).fingerprint)
    }

    func testNativeEnumValidatesExactKeysWithNullAndEmptySeparate() throws {
        let choices = try ValueChoiceSet(choices: [.init(key: "", label: "Empty"), .init(key: "False", label: "No"), .init(key: "other' --", label: "Quoted")],
            source: "PostgreSQL", revision: "enum", origin: .postgresEnum(typeOID: 9001))
        let column = EditableColumn(index: 1, attributeNumber: 2, name: "state", typeOID: 9001,
            typeSQL: "\"custom\".\"state\"", nullable: true, kind: .enumeration, valueChoices: choices)
        for value: DatabaseValue in [.null, .text(""), .text("False"), .text("other' --")] { XCTAssertNoThrow(try EditDraftStore.validate(value, column: column)) }
        XCTAssertThrowsError(try EditDraftStore.validate(.text("false"), column: column))
        XCTAssertThrowsError(try EditDraftStore.validate(.text("No"), column: column), "Never stage the label as the stored key.")
    }

    func testChoiceLimitsDuplicateKeysAndUnresolvedPartialListsFail() throws {
        XCTAssertThrowsError(try ValueChoiceSet(choices: [.init(key: "a", label: "A"), .init(key: "a", label: "Again")], source: "S", revision: "1"))
        XCTAssertThrowsError(try ValueChoiceSet(choices: [.init(key: "\0", label: "NUL")], source: "S", revision: "1"))
        XCTAssertThrowsError(try ValueChoiceSet(choices: [.init(key: "a", label: "Partial")], source: "S", revision: "1", status: .unresolved("Callable")))
        XCTAssertThrowsError(try ValueChoiceSet(choices: [.init(key: "a", label: String(repeating: "a", count: ValueChoiceSet.maximumBytes))], source: "S", revision: "1"))
        let unavailable = try ValueChoiceSet(choices: [], source: "models/example.py", revision: "2", status: .unresolved("Runtime callable"))
        XCTAssertFalse(unavailable.isResolved); XCTAssertTrue(unavailable.statusText.contains("Runtime callable"))
        XCTAssertThrowsError(try unavailable.search(String(repeating: "a", count: 4097)))
    }

    func testProjectChoicesStayAdvisoryAndDoNotOverrideReadOnlyOrTypeConstraints() throws {
        let choices = try ValueChoiceSet(choices: [.init(key: "1", label: "First")], source: "Source", revision: "1")
        let column = EditableColumn(index: 1, attributeNumber: 2, name: "code", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: false, kind: .integer, valueChoices: choices)
        XCTAssertNoThrow(try EditDraftStore.validate(.text("2"), column: column), "Unknown legacy values may be deliberately entered as raw typed values.")
        XCTAssertThrowsError(try EditDraftStore.validate(.text("First"), column: column))
        let generated = EditableColumn(index: 1, attributeNumber: 2, name: "code", typeOID: 23, typeSQL: "pg_catalog.int4", nullable: false, kind: .integer, readOnlyReason: "Generated", valueChoices: choices)
        XCTAssertThrowsError(try EditDraftStore.validate(.text("1"), column: generated))
    }
}
