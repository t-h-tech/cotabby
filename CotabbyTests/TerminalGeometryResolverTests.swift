import CoreGraphics
import XCTest
@testable import Cotabby

final class TerminalGeometryResolverTests: XCTestCase {

    private let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let metrics = TerminalGeometryResolver.defaultCellMetrics

    // MARK: - estimatedCursorRect

    func test_estimatedCursorRect_row1Col1_isNearTopLeft() {
        let rect = TerminalGeometryResolver.estimatedCursorRect(
            windowFrame: windowFrame,
            row: 1,
            column: 1
        )

        // Row 1, Col 1 → zero-based (0,0) → near top-left plus insets (28pt top, 4pt left).
        XCTAssertEqual(rect.origin.x, windowFrame.minX + 4, accuracy: 0.1)
        XCTAssertEqual(rect.origin.y, windowFrame.minY + 28, accuracy: 0.1)
        XCTAssertEqual(rect.width, metrics.cellWidth, accuracy: 0.01)
        XCTAssertEqual(rect.height, metrics.cellHeight, accuracy: 0.01)
    }

    func test_estimatedCursorRect_insideWindowBounds() {
        let rect = TerminalGeometryResolver.estimatedCursorRect(
            windowFrame: windowFrame,
            row: 5,
            column: 10
        )

        XCTAssertGreaterThanOrEqual(rect.origin.x, windowFrame.minX)
        XCTAssertGreaterThanOrEqual(rect.origin.y, windowFrame.minY)
        XCTAssertLessThanOrEqual(rect.maxX, windowFrame.maxX + metrics.cellWidth)
        XCTAssertLessThanOrEqual(rect.maxY, windowFrame.maxY + metrics.cellHeight)
    }

    func test_estimatedCursorRect_movesRightWithColumn() {
        let col5 = TerminalGeometryResolver.estimatedCursorRect(
            windowFrame: windowFrame,
            row: 1,
            column: 5
        )
        let col10 = TerminalGeometryResolver.estimatedCursorRect(
            windowFrame: windowFrame,
            row: 1,
            column: 10
        )

        XCTAssertGreaterThan(col10.origin.x, col5.origin.x)
        // Difference should be 5 columns * cellWidth.
        XCTAssertEqual(
            col10.origin.x - col5.origin.x,
            5 * metrics.cellWidth,
            accuracy: 0.01
        )
    }

    func test_estimatedCursorRect_movesDownWithRow() {
        let row2 = TerminalGeometryResolver.estimatedCursorRect(
            windowFrame: windowFrame,
            row: 2,
            column: 1
        )
        let row5 = TerminalGeometryResolver.estimatedCursorRect(
            windowFrame: windowFrame,
            row: 5,
            column: 1
        )

        XCTAssertGreaterThan(row5.origin.y, row2.origin.y)
        XCTAssertEqual(
            row5.origin.y - row2.origin.y,
            3 * metrics.cellHeight,
            accuracy: 0.01
        )
    }

    func test_estimatedCursorRect_clampsNegativeRowColumn() {
        // Row/col 0 or negative should not produce coordinates above/left of the window.
        let rect = TerminalGeometryResolver.estimatedCursorRect(
            windowFrame: windowFrame,
            row: 0,
            column: -1
        )

        XCTAssertGreaterThanOrEqual(rect.origin.x, windowFrame.minX)
        XCTAssertGreaterThanOrEqual(rect.origin.y, windowFrame.minY)
    }

    func test_estimatedCursorRect_customCellMetrics() {
        let big = TerminalGeometryResolver.CellMetrics(cellWidth: 12.0, cellHeight: 24.0)
        let rect = TerminalGeometryResolver.estimatedCursorRect(
            windowFrame: windowFrame,
            row: 2,
            column: 3,
            cellMetrics: big
        )

        XCTAssertEqual(rect.width, 12.0, accuracy: 0.01)
        XCTAssertEqual(rect.height, 24.0, accuracy: 0.01)
    }

    // MARK: - fallbackCursorRect

    func test_fallbackCursorRect_isNearBottomOfWindow() {
        let rect = TerminalGeometryResolver.fallbackCursorRect(windowFrame: windowFrame)

        // Should be in the bottom half of the window.
        XCTAssertGreaterThan(rect.origin.y, windowFrame.midY)
    }

    func test_fallbackCursorRect_isInsideWindow() {
        let rect = TerminalGeometryResolver.fallbackCursorRect(windowFrame: windowFrame)

        XCTAssertGreaterThanOrEqual(rect.origin.x, windowFrame.minX)
        XCTAssertLessThanOrEqual(rect.maxX, windowFrame.maxX)
        XCTAssertLessThanOrEqual(rect.maxY, windowFrame.maxY)
    }

    func test_fallbackCursorRect_dimensionsMatchDefaultMetrics() {
        let rect = TerminalGeometryResolver.fallbackCursorRect(windowFrame: windowFrame)

        XCTAssertEqual(rect.width, metrics.cellWidth, accuracy: 0.01)
        XCTAssertEqual(rect.height, metrics.cellHeight, accuracy: 0.01)
    }

    // MARK: - defaultCellMetrics

    func test_defaultCellMetrics_areReasonable() {
        // Monospace 13pt should be roughly 7-9pt wide, 15-19pt tall.
        XCTAssertGreaterThan(metrics.cellWidth, 5)
        XCTAssertLessThan(metrics.cellWidth, 15)
        XCTAssertGreaterThan(metrics.cellHeight, 12)
        XCTAssertLessThan(metrics.cellHeight, 25)
    }

    // MARK: - windowFrame(forPid:) edge case

    func test_windowFrame_invalidPid_returnsNil() {
        // PID 0 and negative should return nil without crashing.
        XCTAssertNil(TerminalGeometryResolver.windowFrame(forPid: 0))
        XCTAssertNil(TerminalGeometryResolver.windowFrame(forPid: -1))
    }
}
