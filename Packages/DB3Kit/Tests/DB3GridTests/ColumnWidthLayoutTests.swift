import XCTest
@testable import DB3Grid

final class ColumnWidthLayoutTests: XCTestCase {
    func testMultipleColumnsKeepContentWidthsWhenSpaceIsAvailable() {
        let result = ColumnWidthLayout.widths(preferred: [100, 200, 300], minimum: [50, 50, 50], available: 900)
        assertWidths(result, [100, 200, 300])
        XCTAssertLessThan(result.reduce(0, +), 900)
        assertWidths(ColumnWidthLayout.widths(preferred: [0.25, 0.5], minimum: [], available: 1.5), [0.25, 0.5])
    }

    func testCountColumnRemainsCompactAsViewportGrows() {
        // A short numeric result needs only its measured header/value width.
        for viewport in [120.0, 500, 1800, 4000] {
            assertWidths(ColumnWidthLayout.widths(preferred: [72], minimum: [64], available: viewport), [72])
        }
    }

    func testShrinkingUsesOnlySpaceAboveEachMinimum() {
        let result = ColumnWidthLayout.widths(preferred: [100, 300, 200], minimum: [80, 100, 120], available: 450)
        assertWidths(result, [90, 200, 160])
        XCTAssertEqual(result.reduce(0, +), 450, accuracy: 0.000_001)
    }

    func testNarrowViewPreservesMinimaAndAllowsHorizontalOverflow() {
        let result = ColumnWidthLayout.widths(preferred: [250, 400, 180], minimum: [100, 150, 80], available: 250)
        assertWidths(result, [100, 150, 80])
        XCTAssertGreaterThan(result.reduce(0, +), 250)
        assertWidths(ColumnWidthLayout.widths(preferred: [250, 400, 180], minimum: [100, 150, 80], available: 330), result)
    }

    func testMaximumCapsLongContentWithoutExpandingOtherColumns() {
        let result = ColumnWidthLayout.widths(preferred: [100, 3000], minimum: [50, 50], available: 1800)
        assertWidths(result, [100, 1200])
        let several = ColumnWidthLayout.widths(preferred: [100, 700, 900], minimum: [40, 50, 60], available: 1700, maximum: 600)
        assertWidths(several, [100, 600, 600])
    }

    func testVeryWideViewportLeavesUnusedSpaceAfterContent() {
        let result = ColumnWidthLayout.widths(preferred: [100, 300], minimum: [50, 50], available: 4000)
        assertWidths(result, [100, 300])
        XCTAssertLessThan(result.reduce(0, +), 4000)
    }

    func testMinimumTakesPrecedenceOverMaximumAndPreferenceIsClamped() {
        let result = ColumnWidthLayout.widths(preferred: [10, 9000, 500], minimum: [150, 80, 1600], available: 2950)
        assertWidths(result, [150, 1200, 1600])
        assertWidths(ColumnWidthLayout.widths(preferred: [10, 9000, 500], minimum: [150, 80, 1600], available: 500), [150, 80, 1600])
    }

    func testEmptyInputAndInvalidViewportAreHandled() {
        XCTAssertTrue(ColumnWidthLayout.widths(preferred: [], minimum: [60], available: 500).isEmpty)
        for viewport in [0.0, -100, .nan, .infinity, -.infinity] {
            assertWidths(ColumnWidthLayout.widths(preferred: [100, 200], minimum: [50, 80], available: viewport), [50, 80])
        }
    }

    func testInvalidMeasurementsRemainFiniteAndHonorValidMinima() {
        let result = ColumnWidthLayout.widths(preferred: [.nan, .infinity, -10, 100], minimum: [60, .nan, -20, .infinity], available: 640)
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertGreaterThanOrEqual(result[0], 60)
        assertWidths(result, [60, 0, 0, 100])
        for maximum in [0.0, -1, .nan, .infinity, -.infinity] {
            assertWidths(ColumnWidthLayout.widths(preferred: [2000], minimum: [50], available: 2000, maximum: maximum), [1200])
        }
    }

    func testMismatchedArraysFollowPreferredColumnCount() {
        assertWidths(ColumnWidthLayout.widths(preferred: [100, 200, 300], minimum: [60], available: 0), [60, 0, 0])
        assertWidths(ColumnWidthLayout.widths(preferred: [100], minimum: [60, 9000], available: 200), [100])
    }

    func testZeroPreferencesUseOnlyTheirMinima() {
        assertWidths(ColumnWidthLayout.widths(preferred: [0, 0, 0], minimum: [], available: 300), [0, 0, 0])
        assertWidths(ColumnWidthLayout.widths(preferred: [0, 0], minimum: [20, 40], available: 100, maximum: 30), [20, 40])
    }

    func testViewportResizeCanGrowShrinkAndReturnWithoutAccumulatingWidths() {
        let preferred = [110.0, 420, 240, 85]
        let minimum = [60.0, 80, 80, 60]
        let original = ColumnWidthLayout.widths(preferred: preferred, minimum: minimum, available: 1000)
        let expanded = ColumnWidthLayout.widths(preferred: preferred, minimum: minimum, available: 1800)
        let contracted = ColumnWidthLayout.widths(preferred: preferred, minimum: minimum, available: 500)
        let returned = ColumnWidthLayout.widths(preferred: preferred, minimum: minimum, available: 1000)
        XCTAssertEqual(original, returned)
        assertWidths(original, preferred)
        assertWidths(expanded, preferred)
        for index in preferred.indices {
            XCTAssertLessThan(contracted[index], original[index])
            XCTAssertGreaterThanOrEqual(contracted[index], minimum[index])
        }
        XCTAssertEqual(contracted.reduce(0, +), 500, accuracy: 0.000_001)
    }

    func testManyColumnsShrinkDeterministically() {
        let count = 10_000
        let preferred = (0..<count).map { Double(60 + ($0 % 40) * 20) }
        let minimum = Array(repeating: 40.0, count: count)
        let available = 2_000_000.0
        let result = ColumnWidthLayout.widths(preferred: preferred, minimum: minimum, available: available)
        XCTAssertEqual(result.count, count)
        XCTAssertTrue(result.allSatisfy { $0.isFinite && $0 >= 40 && $0 <= 1200 })
        XCTAssertEqual(result.reduce(0, +), available, accuracy: 0.01)
        XCTAssertEqual(result, ColumnWidthLayout.widths(preferred: preferred, minimum: minimum, available: available))
    }

    func testExtremeFiniteGeometryDoesNotOverflow() {
        let huge = Double.greatestFiniteMagnitude / 2
        let result = ColumnWidthLayout.widths(preferred: [huge, huge, huge], minimum: [1, 1, 1], available: huge, maximum: huge)
        XCTAssertTrue(result.allSatisfy { $0.isFinite && $0 >= 1 })
        XCTAssertEqual(result.map { $0 / huge }.reduce(0, +), 1, accuracy: 0.000_001)
        let overflow = ColumnWidthLayout.widths(preferred: [huge, huge, huge], minimum: [huge, huge, huge], available: huge, maximum: huge)
        XCTAssertEqual(overflow, [huge, huge, huge])
    }

    private func assertWidths(_ actual: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001, file: file, line: line)
        }
    }
}
