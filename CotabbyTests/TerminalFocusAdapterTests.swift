import CoreGraphics
import XCTest
@testable import Cotabby

final class TerminalFocusAdapterTests: XCTestCase {

    // MARK: - Helpers

    private func makeSnapshot(
        commandBuffer: String = "git commit",
        cursorOffset: Int = 10,
        shellType: ShellType = .zsh,
        terminalBundleIdentifier: String = "com.mitchellh.ghostty",
        shellPid: Int32 = 42,
        terminalWindowFrame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600),
        estimatedCursorPosition: CGPoint? = nil,
        cursorRow: Int? = nil,
        cursorColumn: Int? = nil
    ) -> TerminalFocusSnapshot {
        TerminalFocusSnapshot(
            commandBuffer: commandBuffer,
            cursorOffset: cursorOffset,
            shellType: shellType,
            terminalBundleIdentifier: terminalBundleIdentifier,
            shellPid: shellPid,
            terminalWindowFrame: terminalWindowFrame,
            estimatedCursorPosition: estimatedCursorPosition,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            timestamp: Date()
        )
    }

    // MARK: - Zsh cursor offset (character-based, passthrough)

    func test_zshSnapshot_cursorOffsetIsCharacterBased() {
        let snapshot = makeSnapshot(
            commandBuffer: "git ",
            cursorOffset: 4,
            shellType: .zsh
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.precedingText, "git ")
        XCTAssertEqual(adapted.trailingText, "")
    }

    func test_zshSnapshot_cursorInMiddleOfBuffer() {
        let snapshot = makeSnapshot(
            commandBuffer: "git commit",
            cursorOffset: 4,
            shellType: .zsh
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.precedingText, "git ")
        XCTAssertEqual(adapted.trailingText, "commit")
    }

    // MARK: - Bash cursor offset (byte-based, converted)

    func test_bashSnapshot_byteOffsetConvertedToCharacterOffset() {
        // "echo " is 5 bytes. The CJK chars after it don't matter for preceding text.
        let snapshot = makeSnapshot(
            commandBuffer: "echo \u{65E5}\u{672C}\u{8A9E}",
            cursorOffset: 5,  // byte offset: 5 bytes = "echo "
            shellType: .bash
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.precedingText, "echo ")
    }

    func test_bashSnapshot_byteOffsetAtEndOfMultibyteString() {
        // "echo 日本語" in UTF-8: "echo " = 5 bytes, each CJK char = 3 bytes → total 14 bytes.
        let buffer = "echo \u{65E5}\u{672C}\u{8A9E}"
        let snapshot = makeSnapshot(
            commandBuffer: buffer,
            cursorOffset: buffer.utf8.count,
            shellType: .bash
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.precedingText, buffer)
        XCTAssertEqual(adapted.trailingText, "")
    }

    func test_bashSnapshot_byteOffsetZero() {
        let snapshot = makeSnapshot(
            commandBuffer: "hello",
            cursorOffset: 0,
            shellType: .bash
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.precedingText, "")
        XCTAssertEqual(adapted.trailingText, "hello")
    }

    // MARK: - Application name mapping

    func test_applicationName_ghostty() {
        let snapshot = makeSnapshot(terminalBundleIdentifier: "com.mitchellh.ghostty")
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)
        XCTAssertEqual(adapted.applicationName, "Ghostty")
    }

    func test_applicationName_vsCode() {
        let snapshot = makeSnapshot(terminalBundleIdentifier: "com.microsoft.VSCode")
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)
        XCTAssertEqual(adapted.applicationName, "VS Code")
    }

    func test_applicationName_iTerm2() {
        let snapshot = makeSnapshot(terminalBundleIdentifier: "com.googlecode.iterm2")
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)
        XCTAssertEqual(adapted.applicationName, "iTerm2")
    }

    func test_applicationName_unknownBundleId_returnsBundleId() {
        let snapshot = makeSnapshot(terminalBundleIdentifier: "com.example.unknown")
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)
        XCTAssertEqual(adapted.applicationName, "com.example.unknown")
    }

    // MARK: - Caret rect resolution

    func test_caretRect_usesEstimatedCursorPosition() {
        let snapshot = makeSnapshot(
            estimatedCursorPosition: CGPoint(x: 200, y: 300)
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)
        let metrics = TerminalGeometryResolver.defaultCellMetrics

        // Caret rect should be centered on the estimated position.
        XCTAssertEqual(
            adapted.caretRect.origin.x,
            200 - metrics.cellWidth / 2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            adapted.caretRect.origin.y,
            300 - metrics.cellHeight / 2,
            accuracy: 0.01
        )
        XCTAssertEqual(adapted.caretRect.width, metrics.cellWidth, accuracy: 0.01)
        XCTAssertEqual(adapted.caretRect.height, metrics.cellHeight, accuracy: 0.01)
    }

    func test_caretRect_zeroWhenOnlyWindowFrameIsKnown() {
        // A window frame alone is NOT a caret anchor. The old behavior fabricated a
        // bottom-left guess here, which painted ghost text over unrelated screen content;
        // suppression (zero caret → overlay hidden) is the contract now, with the OCR
        // prompt anchor supplying the real position via re-injection moments later.
        let windowFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let snapshot = makeSnapshot(
            terminalWindowFrame: windowFrame,
            estimatedCursorPosition: nil
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.caretRect, .zero)
    }

    func test_caretRect_zeroWhenNoGeometry() {
        let snapshot = makeSnapshot(
            terminalWindowFrame: nil,
            estimatedCursorPosition: nil
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.caretRect, .zero)
    }

    // MARK: - Synthetic field metadata

    func test_role_isTerminalShellInput() {
        let snapshot = makeSnapshot(shellType: .zsh)
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.role, "TerminalShellInput")
        XCTAssertEqual(adapted.subrole, "zsh")
    }

    func test_elementIdentifier_containsShellPid() {
        let snapshot = makeSnapshot(shellPid: 9876)
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.elementIdentifier, "terminal-9876")
    }

    func test_caretQuality_isEstimated() {
        let snapshot = makeSnapshot()
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)
        XCTAssertEqual(adapted.caretQuality, .estimated)
    }

    func test_isSecure_isFalse() {
        let snapshot = makeSnapshot()
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)
        XCTAssertFalse(adapted.isSecure)
    }

    func test_bundleIdentifier_matchesTerminal() {
        let snapshot = makeSnapshot(terminalBundleIdentifier: "com.mitchellh.ghostty")
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)
        XCTAssertEqual(adapted.bundleIdentifier, "com.mitchellh.ghostty")
    }

    func test_focusChangeSequence_passedThrough() {
        let snapshot = makeSnapshot()
        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 42)
        XCTAssertEqual(adapted.focusChangeSequence, 42)
    }

    // MARK: - Empty buffer

    func test_emptyBuffer_producesEmptyTexts() {
        let snapshot = makeSnapshot(
            commandBuffer: "",
            cursorOffset: 0,
            shellType: .zsh
        )

        let adapted = TerminalFocusAdapter.adapt(snapshot, focusChangeSequence: 1)

        XCTAssertEqual(adapted.precedingText, "")
        XCTAssertEqual(adapted.trailingText, "")
    }
}
