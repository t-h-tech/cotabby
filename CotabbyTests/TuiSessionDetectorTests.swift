import XCTest
@testable import Cotabby

/// Locks down the title- and process-name heuristics used to decide whether the focused
/// terminal is hosting Claude Code. Both signals are exercised in isolation; the detector's
/// cheapest-first ordering is implicit in the title-match cases (the process closure is never
/// consulted when the title hits).
final class TuiSessionDetectorTests: XCTestCase {

    // MARK: - Non-terminal short circuit

    /// A non-terminal frontmost app must short-circuit to `.notClaudeCode` regardless of what
    /// the title or process closure say. This is the guard the detector uses to stay cheap on
    /// every focus poll.
    func test_nonTerminalApp_alwaysReturnsNotClaudeCode() {
        let result = TuiSessionDetector.classification(
            bundleIdentifier: "com.apple.notes",
            terminalAccessibilityTitle: "Claude Code — Notes",
            foregroundProcessNames: { ["claude"] }
        )
        XCTAssertEqual(result, .notClaudeCode)
    }

    /// A nil bundle id is treated the same as a non-terminal app — focus snapshots can briefly
    /// be missing the bundle id during fast switches.
    func test_nilBundleId_returnsNotClaudeCode() {
        let result = TuiSessionDetector.classification(
            bundleIdentifier: nil,
            terminalAccessibilityTitle: "Claude Code",
            foregroundProcessNames: { ["claude"] }
        )
        XCTAssertEqual(result, .notClaudeCode)
    }

    // MARK: - Title heuristic

    /// The most common signal: Claude Code sets the terminal title to "Claude Code". A
    /// case-insensitive substring match keeps the detector lenient about terminal-specific
    /// decorations.
    func test_titleContainsClaudeCode_isClassifiedAsClaudeCode() {
        let result = TuiSessionDetector.classification(
            bundleIdentifier: "com.apple.Terminal",
            terminalAccessibilityTitle: "Claude Code — main.swift",
            foregroundProcessNames: {
                XCTFail("Process closure should not be evaluated when the title matches")
                return []
            }
        )
        XCTAssertEqual(result, .claudeCode)
    }

    /// Mixed case: marker matching is case-insensitive so titles emitted by alternate transports
    /// (some shells lowercase the OSC value) still hit.
    func test_titleCaseInsensitive() {
        let result = TuiSessionDetector.classification(
            bundleIdentifier: "com.googlecode.iterm2",
            terminalAccessibilityTitle: "claude-code (main)",
            foregroundProcessNames: { [] }
        )
        XCTAssertEqual(result, .claudeCode)
    }

    /// Negative title control: a benign editor title that happens to contain part of a marker
    /// must NOT produce a `.claudeCode` false positive. The `claude ` marker requires a trailing
    /// space precisely to reject `claudeFix`. With an empty process list (we could not observe the
    /// foreground processes), the detector stays `.unknown` rather than `.notClaudeCode`: per its
    /// contract, a hard "definitely not Claude" verdict comes only from *observed* processes, and a
    /// non-matching title is inconclusive — so the caller can still fall back to an OCR pass.
    func test_titleWithUnrelatedSubstring_doesNotMatch() {
        let result = TuiSessionDetector.classification(
            bundleIdentifier: "com.apple.Terminal",
            terminalAccessibilityTitle: "claudeFix.swift",
            foregroundProcessNames: { [] }
        )
        XCTAssertNotEqual(result, .claudeCode, "The 'claude ' marker's trailing space must reject 'claudeFix'")
        XCTAssertEqual(result, .unknown)
    }

    // MARK: - Process-tree heuristic

    /// When the title is empty (the terminal stripped it), the process-name signal takes over.
    /// `claude` in the foreground process list is conclusive.
    func test_emptyTitleFallsBackToProcessNames() {
        let result = TuiSessionDetector.classification(
            bundleIdentifier: "com.mitchellh.ghostty",
            terminalAccessibilityTitle: nil,
            foregroundProcessNames: { ["zsh", "claude"] }
        )
        XCTAssertEqual(result, .claudeCode)
    }

    /// A populated process list that doesn't contain claude is the strongest "not Claude Code"
    /// signal: we observed the actual foreground processes and none was Claude.
    func test_populatedProcessListWithoutClaudeReturnsNotClaudeCode() {
        let result = TuiSessionDetector.classification(
            bundleIdentifier: "com.apple.Terminal",
            terminalAccessibilityTitle: "",
            foregroundProcessNames: { ["zsh", "vim"] }
        )
        XCTAssertEqual(result, .notClaudeCode)
    }

    /// No signal at all (no title, no observable processes) is `.unknown` so the caller can
    /// decide whether an OCR pass is worth the cost.
    func test_noTitleAndNoProcesses_isUnknown() {
        let result = TuiSessionDetector.classification(
            bundleIdentifier: "com.apple.Terminal",
            terminalAccessibilityTitle: nil,
            foregroundProcessNames: { [] }
        )
        XCTAssertEqual(result, .unknown)
    }
}
