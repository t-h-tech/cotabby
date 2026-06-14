import CoreGraphics
import XCTest
@testable import Cotabby

final class TerminalPromptAnchorResolverTests: XCTestCase {

    // Region: CG screen rect (top-left origin) the OCR boxes are normalized against.
    private let region = CGRect(x: 100, y: 100, width: 800, height: 400)
    private let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 400)
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Vision-style line: normalized [0,1] box with a BOTTOM-LEFT origin. `bottomY` is the
    /// box's minY in Vision space — SMALLER means LOWER on screen.
    private func line(_ text: String, bottomY: CGFloat, minX: CGFloat = 0.0, width: CGFloat = 0.5) -> RecognizedTextLine {
        RecognizedTextLine(
            text: text,
            boundingBox: CGRect(x: minX, y: bottomY, width: width, height: 0.04)
        )
    }

    // MARK: - Normalization

    func test_normalize_foldsPromptGlyphsToAngleBracket() {
        XCTAssertEqual(TerminalPromptAnchorResolver.normalizeForOcrMatch("❯ git"), "> git")
        XCTAssertEqual(TerminalPromptAnchorResolver.normalizeForOcrMatch("› git"), "> git")
        XCTAssertEqual(TerminalPromptAnchorResolver.normalizeForOcrMatch("➜ git"), "> git")
    }

    func test_normalize_collapsesWhitespaceAndTrims() {
        XCTAssertEqual(
            TerminalPromptAnchorResolver.normalizeForOcrMatch("  git   commit  -m   "),
            "git commit -m"
        )
    }

    func test_normalize_keepsAlphanumericsIntact() {
        XCTAssertEqual(
            TerminalPromptAnchorResolver.normalizeForOcrMatch("Cotabby123 test"),
            "Cotabby123 test"
        )
    }

    // MARK: - Matching

    func test_match_findsLineContainingBuffer() {
        let lines = [
            line("Last login: Thu Jun 11", bottomY: 0.9),
            line("user@mac ~ % git checkout", bottomY: 0.1)
        ]

        let match = TerminalPromptAnchorResolver.match(buffer: "git checkout", lines: lines)

        XCTAssertEqual(match?.lineIndex, 1)
    }

    func test_match_mapsNeedleStartBackToRawIndex() {
        // Raw line "❯ git ch": needle "git ch" begins at raw index 2.
        let lines = [line("❯ git ch", bottomY: 0.1)]

        let match = TerminalPromptAnchorResolver.match(buffer: "git ch", lines: lines)

        XCTAssertEqual(match?.rawNeedleStartIndex, 2)
    }

    func test_match_prefersBottomMostWhenDuplicatesExist() {
        // The same command appears in scrollback (higher on screen = larger Vision minY).
        let lines = [
            line("% git status", bottomY: 0.8),
            line("% git status", bottomY: 0.1)
        ]

        let match = TerminalPromptAnchorResolver.match(buffer: "git status", lines: lines)

        XCTAssertEqual(match?.lineIndex, 1, "Bottom-most duplicate is the live prompt")
    }

    func test_match_retriesWithShorterNeedleWhenLongPrefixMissesOcr() {
        // OCR garbled the tail of the line; only the first 12 chars survive.
        let lines = [line("% git checkout#@!garbled", bottomY: 0.1)]

        let match = TerminalPromptAnchorResolver.match(
            buffer: "git checkout -b feature/wow",
            lines: lines
        )

        XCTAssertEqual(match?.lineIndex, 0, "12-char retry should land")
    }

    func test_match_missReturnsNilRatherThanGuessing() {
        let lines = [line("completely unrelated content", bottomY: 0.1)]

        XCTAssertNil(TerminalPromptAnchorResolver.match(buffer: "git status", lines: lines))
    }

    func test_match_emptyBufferPicksBottomMostPromptTerminatedLine() {
        let lines = [
            line("build output here", bottomY: 0.5),
            line("user@mac ~ %", bottomY: 0.1),
            line("more scrollback ❯", bottomY: 0.9)
        ]

        let match = TerminalPromptAnchorResolver.match(buffer: "", lines: lines)

        XCTAssertEqual(match?.lineIndex, 1)
        XCTAssertEqual(match?.rawNeedleStartIndex, Int.max, "Empty-buffer sentinel")
    }

    // MARK: - Anchor construction

    func test_makeAnchor_mapsVisionBoxToScreenAndCalibratesCellWidth() {
        // 40-char line, normalized width 0.4 of an 800pt region → 320pt → cellWidth 8.
        let text = String(repeating: "a", count: 38) + " %"
        let lines = [line(text, bottomY: 0.1, minX: 0.0, width: 0.4)]
        let match = TerminalPromptAnchorResolver.LineMatch(lineIndex: 0, rawNeedleStartIndex: 0)

        let anchor = TerminalPromptAnchorResolver.makeAnchor(
            match: match, lines: lines, region: region,
            windowFrame: windowFrame, shellPid: 42, now: now
        )

        XCTAssertNotNil(anchor)
        XCTAssertEqual(anchor?.cellWidth ?? 0, 8.0, accuracy: 0.01)
        // Vision box minY 0.1, height 0.04 → maxY 0.14 → CG y = 100 + (1-0.14)*400 = 444.
        XCTAssertEqual(anchor?.promptLineRect.minY ?? 0, 444, accuracy: 0.5)
        XCTAssertEqual(anchor?.promptLineRect.minX ?? 0, 100, accuracy: 0.5)
    }

    func test_makeAnchor_rejectsImplausibleCellWidth() {
        // 4 chars across 0.4*800 = 320pt → 80pt/char: clearly a mis-segmented OCR line.
        let lines = [line("ab c", bottomY: 0.1, width: 0.4)]
        let match = TerminalPromptAnchorResolver.LineMatch(lineIndex: 0, rawNeedleStartIndex: 0)

        XCTAssertNil(TerminalPromptAnchorResolver.makeAnchor(
            match: match, lines: lines, region: region,
            windowFrame: windowFrame, shellPid: 42, now: now
        ))
    }

    func test_makeAnchor_emptyBufferStartsOneCellPastLineEnd() {
        let text = String(repeating: "x", count: 39) + "%"
        let lines = [line(text, bottomY: 0.1, width: 0.4)]
        let match = TerminalPromptAnchorResolver.LineMatch(lineIndex: 0, rawNeedleStartIndex: Int.max)

        let anchor = TerminalPromptAnchorResolver.makeAnchor(
            match: match, lines: lines, region: region,
            windowFrame: windowFrame, shellPid: 42, now: now
        )

        XCTAssertEqual(anchor?.isLowConfidence, true)
        // line spans 100..420 (0.4*800=320 wide), cell 8 → bufferStartX = 420 + 8 = 428.
        XCTAssertEqual(anchor?.bufferStartX ?? 0, 428, accuracy: 0.5)
    }

    // MARK: - Arithmetic caret tracking

    private func makeTestAnchor(
        bufferStartX: CGFloat = 180,
        cellWidth: CGFloat = 8,
        totalColumns: Int = 100
    ) -> TerminalPromptAnchor {
        TerminalPromptAnchor(
            shellPid: 42,
            windowFrame: windowFrame,
            paneFrame: region,
            promptLineRect: CGRect(x: 100, y: 440, width: 320, height: 16),
            cellWidth: cellWidth,
            cellHeight: 16,
            bufferStartX: bufferStartX,
            totalColumns: totalColumns,
            isLowConfidence: false,
            capturedAt: now
        )
    }

    func test_caretRect_advancesOneCellPerCharacter() {
        let anchor = makeTestAnchor()

        let at0 = TerminalPromptAnchorResolver.caretRect(cursorOffset: 0, anchor: anchor)
        let at5 = TerminalPromptAnchorResolver.caretRect(cursorOffset: 5, anchor: anchor)

        XCTAssertEqual(at0.minX, 180, accuracy: 0.5)
        XCTAssertEqual(at5.minX, 180 + 5 * 8, accuracy: 0.5)
        XCTAssertEqual(at0.minY, at5.minY, "Same row while under the column limit")
    }

    func test_caretRect_wrapsToNextRowAtColumnLimit() {
        // bufferStart at column 10; 100 columns total → offset 95 crosses into row 1.
        let anchor = makeTestAnchor(bufferStartX: 180, cellWidth: 8, totalColumns: 100)

        let wrapped = TerminalPromptAnchorResolver.caretRect(cursorOffset: 95, anchor: anchor)

        // linear = 10 + 95 = 105 → row 1, col 5. CG rows grow DOWNWARD (+y).
        XCTAssertEqual(wrapped.minY, 440 + 16, accuracy: 0.5)
        XCTAssertEqual(wrapped.minX, 100 + 5 * 8, accuracy: 0.5)
    }

    func test_inputLineRect_spansPaneWidthAtCaretRow() {
        let anchor = makeTestAnchor()

        let rect = TerminalPromptAnchorResolver.inputLineRect(cursorOffset: 0, anchor: anchor)

        XCTAssertEqual(rect.minX, region.minX)
        XCTAssertEqual(rect.width, region.width)
        XCTAssertEqual(rect.height, 16)
    }

    // MARK: - Validity

    func test_isValid_rejectsMovedWindow() {
        let anchor = makeTestAnchor()
        let moved = windowFrame.offsetBy(dx: 30, dy: 0)

        XCTAssertFalse(TerminalPromptAnchorResolver.isValid(
            anchor, currentWindowFrame: moved, cursorOffset: 0, now: now
        ))
    }

    func test_isValid_rejectsExpiredAnchor() {
        let anchor = makeTestAnchor()
        let later = now.addingTimeInterval(TerminalPromptAnchorResolver.defaultMaxAge + 1)

        XCTAssertFalse(TerminalPromptAnchorResolver.isValid(
            anchor, currentWindowFrame: windowFrame, cursorOffset: 0, now: later
        ))
    }

    func test_isValid_rejectsCaretOutsideWindow() {
        // A huge offset pushes the arithmetic caret below the window — stale anchor.
        let anchor = makeTestAnchor()

        XCTAssertFalse(TerminalPromptAnchorResolver.isValid(
            anchor, currentWindowFrame: windowFrame, cursorOffset: 10_000, now: now
        ))
    }

    func test_isValid_acceptsFreshAnchorInPlace() {
        let anchor = makeTestAnchor()

        XCTAssertTrue(TerminalPromptAnchorResolver.isValid(
            anchor, currentWindowFrame: windowFrame, cursorOffset: 4,
            now: now.addingTimeInterval(1)
        ))
    }
}
