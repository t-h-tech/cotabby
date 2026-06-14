import CoreGraphics
import Foundation

/// File overview:
/// Bridges the terminal shell-integration data source into the existing suggestion pipeline by
/// converting `TerminalFocusSnapshot` into `FocusedInputSnapshot`.
///
/// The suggestion pipeline — `SuggestionRequestFactory`, `SuggestionCoordinator`, overlay
/// positioning — all consume `FocusedInputSnapshot`. Rather than forking that pipeline, this
/// adapter maps terminal-sourced data into the same shape, filling in synthetic values for fields
/// that have no terminal analogue (e.g. `role`, `isSecure`, `elementIdentifier`).
enum TerminalFocusAdapter {

    /// Converts a terminal snapshot into a `FocusedInputSnapshot` that the suggestion pipeline
    /// can consume directly.
    ///
    /// - Parameters:
    ///   - snapshot: The terminal focus state received from a shell hook.
    ///   - focusChangeSequence: The monotonic focus-change counter from `FocusTracker`. Callers
    ///     must provide the current sequence value so downstream staleness checks work correctly.
    /// - Returns: A `FocusedInputSnapshot` with terminal-appropriate defaults.
    /// - Parameters:
    ///   - snapshot: The terminal focus state received from a shell hook.
    ///   - terminalPid: The terminal app's process identifier (e.g. Ghostty's PID), not the
    ///     shell's PID. The overlay system uses this to find the terminal's window.
    ///   - focusChangeSequence: The monotonic focus-change counter from `FocusTracker`.
    static func adapt(
        _ snapshot: TerminalFocusSnapshot,
        terminalPid: Int32? = nil,
        focusChangeSequence: UInt64
    ) -> FocusedInputSnapshot {
        let caretRect = resolveCaret(from: snapshot)
        let cursorCharacterOffset = resolvedCursorOffset(from: snapshot)
        let resolvedPid = terminalPid ?? snapshot.shellPid

        return FocusedInputSnapshot(
            applicationName: applicationName(for: snapshot.terminalBundleIdentifier),
            bundleIdentifier: snapshot.terminalBundleIdentifier,
            processIdentifier: resolvedPid,
            elementIdentifier: "terminal-\(snapshot.shellPid)",
            role: "TerminalShellInput",
            subrole: snapshot.shellType.rawValue,
            caretRect: caretRect,
            inputFrameRect: snapshot.promptLineRect ?? snapshot.terminalWindowFrame,
            caretSource: "TerminalShellIntegration",
            caretQuality: .estimated,
            observedCharWidth: snapshot.observedCellWidth
                ?? TerminalGeometryResolver.defaultCellMetrics.cellWidth,
            precedingText: precedingText(
                from: snapshot.commandBuffer,
                cursorOffset: cursorCharacterOffset
            ),
            trailingText: trailingText(
                from: snapshot.commandBuffer,
                cursorOffset: cursorCharacterOffset
            ),
            selection: NSRange(location: cursorCharacterOffset, length: 0),
            isSecure: false,
            focusChangeSequence: focusChangeSequence
        )
    }

    // MARK: - Private

    /// Resolves the caret rect from the snapshot's geometry data.
    ///
    /// Only ANCHORED geometry produces a caret: the OCR-calibrated rect, or a cursor position
    /// computed from shell-reported row/col. The old "near the bottom of the window" guess is
    /// deliberately gone — it painted ghost text over unrelated screen content at the window's
    /// bottom-left (observed in every terminal), which is strictly worse than briefly showing
    /// nothing while the prompt anchor resolves (~250–400 ms after the first keystroke).
    private static func resolveCaret(from snapshot: TerminalFocusSnapshot) -> CGRect {
        if let anchored = snapshot.estimatedCursorRect {
            return anchored
        }

        if let cursorPos = snapshot.estimatedCursorPosition {
            let metrics = TerminalGeometryResolver.defaultCellMetrics
            return CGRect(
                x: cursorPos.x - metrics.cellWidth / 2,
                y: cursorPos.y - metrics.cellHeight / 2,
                width: metrics.cellWidth,
                height: metrics.cellHeight
            )
        }

        // No anchored geometry — return a zero rect. The overlay system will not display
        // when the caret rect is zero-sized; generation still runs so the suggestion is
        // ready the moment the anchor lands and the snapshot is re-injected.
        return .zero
    }

    /// Resolves the cursor offset to a character offset regardless of shell type.
    ///
    /// Bash's `READLINE_POINT` is a byte offset into the UTF-8 buffer. Zsh's `$CURSOR` is
    /// already a character offset. This normalizes both to character offsets.
    private static func resolvedCursorOffset(from snapshot: TerminalFocusSnapshot) -> Int {
        switch snapshot.shellType {
        case .bash:
            return byteOffsetToCharacterOffset(
                snapshot.cursorOffset,
                in: snapshot.commandBuffer
            )
        case .zsh, .fish:
            return snapshot.cursorOffset
        }
    }

    /// Converts a UTF-8 byte offset to a Swift character offset.
    private static func byteOffsetToCharacterOffset(_ byteOffset: Int, in string: String) -> Int {
        let utf8 = string.utf8
        let clampedOffset = min(byteOffset, utf8.count)
        guard let targetIndex = utf8.index(
            utf8.startIndex,
            offsetBy: clampedOffset,
            limitedBy: utf8.endIndex
        ) else {
            return string.count
        }
        return string.distance(from: string.startIndex, to: targetIndex)
    }

    private static func precedingText(from buffer: String, cursorOffset: Int) -> String {
        guard cursorOffset >= 0, cursorOffset <= buffer.count else { return buffer }
        let index = buffer.index(
            buffer.startIndex,
            offsetBy: cursorOffset,
            limitedBy: buffer.endIndex
        ) ?? buffer.endIndex
        return String(buffer[..<index])
    }

    private static func trailingText(from buffer: String, cursorOffset: Int) -> String {
        guard cursorOffset >= 0, cursorOffset <= buffer.count else { return "" }
        let index = buffer.index(
            buffer.startIndex,
            offsetBy: cursorOffset,
            limitedBy: buffer.endIndex
        ) ?? buffer.endIndex
        return String(buffer[index...])
    }

    /// Human-readable names for menu bar display, keyed by terminal bundle identifier.
    private static let displayNamesByBundleIdentifier: [String: String] = [
        "com.mitchellh.ghostty": "Ghostty",
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "net.kovidgoyal.kitty": "Kitty",
        "io.alacritty": "Alacritty",
        "co.zeit.hyper": "Hyper",
        "dev.warp.Warp-Stable": "Warp",
        "com.github.wez.wezterm": "WezTerm",
        "io.rio.terminal": "Rio",
        "com.microsoft.VSCode": "VS Code"
    ]

    /// Maps a terminal bundle identifier to a human-readable name for menu bar display.
    private static func applicationName(for bundleIdentifier: String) -> String {
        displayNamesByBundleIdentifier[bundleIdentifier] ?? bundleIdentifier
    }
}
