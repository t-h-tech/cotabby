import Foundation

/// Identifies terminal emulator applications by bundle identifier and classifies how Cotabby
/// should interact with them.
///
/// Without shell integration, terminal apps are blocked because they do not expose the macOS
/// Accessibility attributes Cotabby needs (editable text value, selection range, caret bounds).
/// When the user installs Cotabby's shell hooks and a live IPC session exists, the terminal
/// transitions to `.shellIntegration` and the suggestion pipeline uses the hook-provided data
/// instead of AX.
enum TerminalAppDetector {
    /// How Cotabby should interact with the focused app.
    enum SupportLevel: Equatable, Sendable {
        /// A known terminal without an active shell integration session. Suggestions are blocked.
        case blocked
        /// A known terminal with an active shell integration session. Suggestions use IPC data.
        case shellIntegration
        /// Not a terminal. Suggestions use the standard AX pipeline.
        case nonTerminal
    }

    /// Bundle identifiers of well-known macOS terminal emulators.
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.rio.terminal"
    ]

    /// Apps that are not terminals themselves but EMBED one (integrated terminal panes).
    /// These get shell-surface treatment — terminal accept key, inline ghost rendering —
    /// only while one of their shells holds a live integration session, because unlike a
    /// dedicated terminal the user is usually typing in an editor pane, not a shell.
    private static let embeddedTerminalHostBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
        "com.jetbrains.intellij"
    ]

    /// Returns true if the bundle identifier belongs to a known terminal emulator.
    ///
    /// This is the original check, preserved for call sites that only need a binary answer.
    static func isTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Returns true if the app hosts an embedded terminal (see
    /// `embeddedTerminalHostBundleIdentifiers`). Callers combine this with "does this app
    /// currently have a live shell-integration session" to decide shell-surface behavior.
    static func hostsEmbeddedTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return embeddedTerminalHostBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Classifies how Cotabby should handle the given app, taking shell integration state
    /// into account.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The focused app's bundle identifier.
    ///   - hasActiveShellIntegration: Whether `TerminalIntegrationService` has a live session
    ///     for a shell running inside this terminal.
    static func supportLevel(
        bundleIdentifier: String?,
        hasActiveShellIntegration: Bool = false
    ) -> SupportLevel {
        guard let bundleIdentifier else { return .nonTerminal }

        guard terminalBundleIdentifiers.contains(bundleIdentifier) else {
            return .nonTerminal
        }

        return hasActiveShellIntegration ? .shellIntegration : .blocked
    }
}
