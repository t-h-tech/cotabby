import CoreGraphics
import Foundation

/// File overview:
/// Bridges a `TuiContextReader.PromptReading` (extracted from a Claude Code prompt screenshot)
/// into the `FocusedInputSnapshot` shape the suggestion pipeline already consumes.
///
/// **Same shape, different source.** `TerminalFocusAdapter` already does this trick for
/// shell-integration data; we keep both adapters lean and parallel so future maintainers can
/// reason about each input source independently. A new role string (`ClaudeCodeTuiInput`) lets
/// downstream code spot TUI snapshots without re-checking the bundle id.
///
/// **Caret quality.** OCR-derived caret data is intrinsically imprecise: there's no real caret
/// glyph to lock onto. We mark the snapshot as `.estimated` so the existing
/// `CompletionRenderModePolicy` routes it into the popup card path (`MirrorPreference`) instead
/// of pixel-perfect inline ghost text. This matches what shell-integration snapshots already do
/// and avoids a separate render policy.
enum TuiFocusAdapter {

    /// Identity of the terminal hosting the Claude Code TUI. The TUI piggybacks on the
    /// terminal app for window resolution and per-app overrides, so the active bundle id,
    /// display name, and PID are all the terminal's — never the `claude` subprocess's.
    struct HostTerminal {
        let bundleIdentifier: String
        let applicationName: String
        let pid: Int32
    }

    /// Convert a single OCR'd prompt reading into a `FocusedInputSnapshot`.
    ///
    /// - Parameters:
    ///   - reading: The OCR result. `promptText` lands in `precedingText`; trailingText is
    ///     always empty because Claude Code only ever appends to the input line.
    ///   - terminal: Identity of the hosting terminal (Ghostty, iTerm2, etc.) — bundle id,
    ///     display name, and PID. The TUI piggybacks on the terminal app for window resolution
    ///     and per-app overrides, and the PID is the terminal's, NOT the `claude` subprocess's.
    ///   - promptCaretRect: Estimated caret rectangle in global screen coordinates. Callers
    ///     compute this from the OCR'd region's frame plus a last-line offset; the adapter does
    ///     no geometry math of its own so this file stays pure and unit-testable.
    ///   - inputFrameRect: Approximate Claude Code input-box rect. Used by the overlay layout
    ///     to clamp the suggestion to the input bounds. Optional — falls through to the
    ///     terminal window frame at the call site when unavailable.
    ///   - focusChangeSequence: The monotonic counter from `FocusTracker`. Stamping every TUI
    ///     snapshot lets the staleness guard cancel in-flight requests when the user switches
    ///     out of Claude Code.
    static func adapt(
        reading: TuiContextReader.PromptReading,
        terminal: HostTerminal,
        promptCaretRect: CGRect,
        inputFrameRect: CGRect?,
        focusChangeSequence: UInt64
    ) -> FocusedInputSnapshot {
        let terminalBundleIdentifier = terminal.bundleIdentifier
        let terminalApplicationName = terminal.applicationName
        let terminalPid = terminal.pid
        let promptText = reading.promptText
        // Claude Code only accepts input at the end of the editable line, so trailingText is
        // always empty. Encoding this here (rather than at the caller) keeps the contract
        // explicit: TUI snapshots are append-only.
        let cursorCharacterOffset = min(reading.estimatedCursorOffset, promptText.count)

        return FocusedInputSnapshot(
            applicationName: terminalApplicationName,
            bundleIdentifier: terminalBundleIdentifier,
            processIdentifier: terminalPid,
            // Distinct identifier so the focus-change tracker treats Claude Code's input as a
            // different "field" than the bare shell prompt that may have preceded it. Without
            // this, stepping from `zsh` into `claude` would not bump the field identity and
            // leftover suggestion state could leak across the transition.
            elementIdentifier: "tui-claude-code-\(terminalPid)",
            role: "ClaudeCodeTuiInput",
            subrole: "OCR",
            caretRect: promptCaretRect,
            inputFrameRect: inputFrameRect,
            caretSource: "TuiOCR",
            caretQuality: .estimated,
            // Cell width isn't really meaningful for an OCR'd region; pass the same default
            // metric the shell-integration adapter uses so the overlay layout has *something*
            // sensible to size with.
            observedCharWidth: TerminalGeometryResolver.defaultCellMetrics.cellWidth,
            precedingText: String(promptText.prefix(cursorCharacterOffset)),
            trailingText: String(promptText.dropFirst(cursorCharacterOffset)),
            selection: NSRange(location: cursorCharacterOffset, length: 0),
            isSecure: false,
            focusChangeSequence: focusChangeSequence
        )
    }
}
