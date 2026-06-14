import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks down the OCR-reading → `FocusedInputSnapshot` adapter for the Claude Code TUI path.
/// The adapter is intentionally pure so these tests can run without ScreenCaptureKit, Vision,
/// or any Accessibility access.
final class TuiFocusAdapterTests: XCTestCase {

    /// The adapter must put the OCR'd text into `precedingText` (everything to the left of the
    /// cursor) because Claude Code only ever appends to the input line. `trailingText` is
    /// always empty so the suggestion model sees an append-only buffer.
    func test_adapt_putsPromptIntoPrecedingTextOnly() {
        let reading = TuiContextReader.PromptReading(
            promptText: "Explain why",
            estimatedCursorOffset: 11,
            latencyMilliseconds: 50,
            recognizedLineCount: 1
        )
        let snapshot = TuiFocusAdapter.adapt(
            reading: reading,
            terminalBundleIdentifier: "com.mitchellh.ghostty",
            terminalApplicationName: "Ghostty",
            terminalPid: 4242,
            promptCaretRect: CGRect(x: 100, y: 200, width: 8, height: 16),
            inputFrameRect: nil,
            focusChangeSequence: 7
        )
        XCTAssertEqual(snapshot.precedingText, "Explain why")
        XCTAssertEqual(snapshot.trailingText, "")
        XCTAssertEqual(snapshot.selection, NSRange(location: 11, length: 0))
    }

    /// The role string drives downstream routing: per-app overrides, suggestion availability,
    /// and the new TUI router (Sub-plan D) all key off "ClaudeCodeTuiInput". This is the load-
    /// bearing string for distinguishing TUI snapshots from shell-prompt snapshots.
    func test_adapt_setsRoleAndCaretQualityForTuiRouting() {
        let reading = TuiContextReader.PromptReading(
            promptText: "git status",
            estimatedCursorOffset: 10,
            latencyMilliseconds: 80,
            recognizedLineCount: 1
        )
        let snapshot = TuiFocusAdapter.adapt(
            reading: reading,
            terminalBundleIdentifier: "com.mitchellh.ghostty",
            terminalApplicationName: "Ghostty",
            terminalPid: 4242,
            promptCaretRect: .zero,
            inputFrameRect: nil,
            focusChangeSequence: 0
        )
        XCTAssertEqual(snapshot.role, "ClaudeCodeTuiInput")
        XCTAssertEqual(snapshot.caretQuality, .estimated)
        XCTAssertEqual(snapshot.bundleIdentifier, "com.mitchellh.ghostty")
    }

    /// The element identifier embeds the terminal PID so the focus-change tracker treats a
    /// move from the bare shell prompt to Claude Code as a real field switch and clears any
    /// leftover suggestion state.
    func test_adapt_elementIdentifierIsTerminalScoped() {
        let reading = TuiContextReader.PromptReading(
            promptText: "",
            estimatedCursorOffset: 0,
            latencyMilliseconds: 0,
            recognizedLineCount: 0
        )
        let snapshot = TuiFocusAdapter.adapt(
            reading: reading,
            terminalBundleIdentifier: "com.apple.Terminal",
            terminalApplicationName: "Terminal",
            terminalPid: 9999,
            promptCaretRect: .zero,
            inputFrameRect: nil,
            focusChangeSequence: 0
        )
        XCTAssertEqual(snapshot.elementIdentifier, "tui-claude-code-9999")
    }

    /// An out-of-bounds cursor offset (OCR error or model surprise) must clamp to the prompt
    /// length so the prefix/suffix split never crashes the suggestion pipeline.
    func test_adapt_clampsOutOfBoundsCursorOffset() {
        let reading = TuiContextReader.PromptReading(
            promptText: "hi",
            estimatedCursorOffset: 999,
            latencyMilliseconds: 0,
            recognizedLineCount: 1
        )
        let snapshot = TuiFocusAdapter.adapt(
            reading: reading,
            terminalBundleIdentifier: "com.mitchellh.ghostty",
            terminalApplicationName: "Ghostty",
            terminalPid: 1,
            promptCaretRect: .zero,
            inputFrameRect: nil,
            focusChangeSequence: 0
        )
        XCTAssertEqual(snapshot.precedingText, "hi")
        XCTAssertEqual(snapshot.selection.location, 2)
    }
}
