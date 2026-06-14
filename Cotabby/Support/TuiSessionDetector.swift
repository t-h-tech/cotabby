import Foundation

/// File overview:
/// Decides whether the focused terminal is currently running the Claude Code TUI (a full-screen
/// terminal app that takes over stdin, so the existing shell-integration hooks see nothing).
///
/// **Why this is its own type, separate from `TerminalAppDetector`.** Shell-integration sessions
/// answer "is a shell prompt visible?" — that's what the existing zsh/bash/fish hooks report. A
/// TUI subprocess hides the prompt and owns the screen, so the only ways to detect it are
/// out-of-band: the terminal title, the foreground PID's process name, or the on-screen pixels.
/// Keeping the heuristics here lets the rest of the pipeline route on a single
/// `TuiSessionDetector.classification(...)` value rather than reasoning about each signal.
///
/// **Cheapest-first ordering.** Heuristics run in the listed order and the first match wins. This
/// matters because the detector runs in the focus-poll hot path and on every keystroke that
/// drives a TUI snapshot.
///   1. **Title hint** — terminal `AXTitle` strings that contain a Claude Code marker
///      ("Claude Code", "claude-code", or the literal `claude` command name). Cheapest signal
///      because the title is already read by AX for other reasons.
///   2. **Foreground PID's process name** — walk the descendants of the terminal PID and look
///      for `claude` / `claude-code` (or fall back to the shell session's PID, since the shell
///      knows its TTY's foreground process). Slightly more expensive (proc info syscall) but
///      authoritative when titles are stripped.
///   3. **OCR fingerprint** — left to `TuiContextReader` (Sub-plan C.2). The detector returns
///      `.unknown` so the caller can decide whether to spend on a screenshot pass.
///
/// The detector is pure: callers pass in the title and a process-tree lookup closure so the
/// heuristics can be exercised under test without touching `proc_listpids` or `AXUIElement`.
enum TuiSessionDetector {

    /// Result of classification. `.notClaudeCode` is the negative case (definitely not Claude
    /// Code, route via the existing AX / shell-integration paths). `.claudeCode` means at least
    /// one heuristic matched. `.unknown` means no heuristic could confirm or deny — used so the
    /// caller can fall back to an OCR fingerprint without wasting a screenshot pass on every
    /// keystroke.
    enum Classification: Equatable, Sendable {
        case claudeCode
        case notClaudeCode
        case unknown
    }

    /// Title-bar markers that Claude Code sets via OSC 0 / OSC 2 escape sequences (most terminals
    /// surface these as `AXTitle`). The list is intentionally lenient so renamings of the binary
    /// or terminal-specific decorations ("/Users/you — claude — 80×24") still match.
    static let claudeCodeTitleMarkers: [String] = [
        "Claude Code",
        "claude-code",
        // The CLI's own banner shortens to "claude" in many terminals — match defensively but
        // anchor it to a word boundary so editor windows named "claudeFix.swift" don't match.
        "claude "
    ]

    /// Process basenames that the foreground-process walk should treat as Claude Code.
    static let claudeCodeProcessNames: Set<String> = [
        "claude",
        "claude-code"
    ]

    /// Classify the focused terminal.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The focused app's bundle id (`FocusTrackingModel.snapshot`).
    ///     A non-terminal frontmost app short-circuits to `.notClaudeCode` so the caller does
    ///     not have to gate on `TerminalAppDetector.isTerminal` separately.
    ///   - terminalAccessibilityTitle: The focused window's `AXTitle`, if available. Many
    ///     terminals (Terminal.app, iTerm2, Ghostty, WezTerm) update this from the running
    ///     program's OSC sequence, so a Claude-Code-aware match is very cheap when it works.
    ///   - foregroundProcessNames: A closure that returns the basenames of processes running
    ///     under the terminal — typically descendants of the terminal PID, or descendants of the
    ///     shell PID reported by the shell-integration hook. The closure is invoked at most once
    ///     per call so an expensive sysctl walk is paid only when the title check is empty.
    /// - Returns: The detector's classification. The caller decides whether `.unknown` is worth
    ///   an OCR pass.
    static func classification(
        bundleIdentifier: String?,
        terminalAccessibilityTitle: String?,
        foregroundProcessNames: () -> [String]
    ) -> Classification {
        // TUIs only matter inside something that can host one: a dedicated terminal, or an
        // embedded-terminal host (VS Code's integrated terminal runs Claude Code too — the
        // process-tree heuristic below finds `claude` under the host app's pid either way).
        // Skipping the title and process checks for everything else keeps the detector cheap
        // on every focus poll.
        guard TerminalAppDetector.isTerminal(bundleIdentifier: bundleIdentifier)
                || TerminalAppDetector.hostsEmbeddedTerminal(bundleIdentifier: bundleIdentifier) else {
            return .notClaudeCode
        }

        if let title = terminalAccessibilityTitle, !title.isEmpty {
            // Case-insensitive substring match so a title like "Claude Code — main.swift" hits
            // regardless of terminal decorations. The marker list is short, so iterating is fine.
            for marker in claudeCodeTitleMarkers
            where title.range(of: marker, options: .caseInsensitive) != nil {
                return .claudeCode
            }
        }

        // Title was empty or didn't match — fall back to the foreground process. We deliberately
        // evaluate the closure here (not before the title check) so a Sequence-of-zsh-prompts
        // session pays the title-only price.
        let processes = foregroundProcessNames()
        if processes.contains(where: { claudeCodeProcessNames.contains($0) }) {
            return .claudeCode
        }
        // Neither heuristic matched. Caller decides whether OCR is worth the cost.
        return processes.isEmpty ? .unknown : .notClaudeCode
    }
}
