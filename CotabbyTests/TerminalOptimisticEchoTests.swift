import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Covers `TerminalFocusSnapshot.appendingInsertedText` — the optimistic local echo applied
/// after Cotabby's own terminal paste. Bracketed paste never reaches the shell hooks, so this
/// copy is what keeps the live snapshot truthful between the paste and the next real keystroke.
final class TerminalOptimisticEchoTests: XCTestCase {

    private func makeSnapshot(
        buffer: String,
        cursorOffset: Int,
        shellType: ShellType = .zsh
    ) -> TerminalFocusSnapshot {
        TerminalFocusSnapshot(
            commandBuffer: buffer,
            cursorOffset: cursorOffset,
            shellType: shellType,
            terminalBundleIdentifier: "com.mitchellh.ghostty",
            shellPid: 42,
            terminalWindowFrame: nil,
            estimatedCursorPosition: nil,
            cursorRow: nil,
            cursorColumn: nil,
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    func test_appendingInsertedText_insertsAtCursorAndAdvances() {
        let snapshot = makeSnapshot(buffer: "git", cursorOffset: 3)

        let echoed = snapshot.appendingInsertedText(" pull")

        XCTAssertEqual(echoed.commandBuffer, "git pull")
        XCTAssertEqual(echoed.cursorOffset, 8)
        XCTAssertEqual(echoed.precedingText, "git pull")
        XCTAssertEqual(echoed.trailingText, "")
    }

    func test_appendingInsertedText_preservesLeadingSpaceOfChunk() {
        // The exact user-reported bug shape: "git pull" + " origin" must stay "git pull origin",
        // never "git pullorigin".
        let snapshot = makeSnapshot(buffer: "git pull", cursorOffset: 8)

        let echoed = snapshot.appendingInsertedText(" origin")

        XCTAssertEqual(echoed.commandBuffer, "git pull origin")
        XCTAssertFalse(echoed.precedingText.hasSuffix("  "), "No double space introduced")
    }

    func test_appendingInsertedText_midBufferKeepsTrailingText() {
        let snapshot = makeSnapshot(buffer: "git  --force", cursorOffset: 4)

        let echoed = snapshot.appendingInsertedText("push")

        XCTAssertEqual(echoed.commandBuffer, "git push --force")
        XCTAssertEqual(echoed.cursorOffset, 8)
        XCTAssertEqual(echoed.trailingText, " --force")
    }

    func test_appendingInsertedText_bashAdvancesByBytes() {
        // bash's READLINE_POINT is a UTF-8 byte offset; multi-byte insertions must advance
        // in bytes or the next preceding/trailing split drifts.
        let snapshot = makeSnapshot(buffer: "echo ", cursorOffset: 5, shellType: .bash)

        let echoed = snapshot.appendingInsertedText("héllo")

        XCTAssertEqual(echoed.commandBuffer, "echo héllo")
        XCTAssertEqual(echoed.cursorOffset, 5 + "héllo".utf8.count)
    }

    func test_appendingInsertedText_zshAdvancesByCharacters() {
        let snapshot = makeSnapshot(buffer: "echo ", cursorOffset: 5, shellType: .zsh)

        let echoed = snapshot.appendingInsertedText("héllo")

        XCTAssertEqual(echoed.cursorOffset, 10)
    }

    func test_appendingInsertedText_refreshesTimestamp() {
        let snapshot = makeSnapshot(buffer: "git", cursorOffset: 3)

        let echoed = snapshot.appendingInsertedText(" pull")

        XCTAssertGreaterThan(echoed.timestamp, snapshot.timestamp)
    }
}
