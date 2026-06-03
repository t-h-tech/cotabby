import CoreGraphics
import Foundation

/// File overview:
/// Pure value types for the terminal shell-integration subsystem. These types carry data received
/// from shell hooks (zsh `zle`, bash `bind -x`) over a Unix domain socket, and let the rest of
/// Cotabby reason about terminal state without depending on Accessibility attributes that terminals
/// do not expose.

/// The shell interpreter that is reporting its command buffer.
///
/// Each shell exposes buffer/cursor state through different mechanisms (zle, READLINE, `commandline`),
/// so the type tag lets downstream code adjust expectations — e.g. cursor offset encoding differs
/// between bash (byte offset) and zsh (character offset).
enum ShellType: String, Codable, Equatable, Sendable {
    case zsh
    case bash
    case fish
}

/// One IPC message received from a shell hook over the Unix socket.
///
/// The message format is line-delimited JSON. Each line is one `TerminalIpcMessage`.
/// The `type` discriminator allows future message kinds (e.g. session close, heartbeat)
/// without breaking the parser.
struct TerminalIpcMessage: Codable, Equatable, Sendable {
    /// Discriminator for the message kind.
    enum MessageType: String, Codable, Sendable {
        /// The shell is reporting its current command buffer and cursor position.
        case buffer
        /// The shell session is ending (user typed `exit`, closed the tab, etc.).
        case disconnect
    }

    let type: MessageType
    /// Current contents of the shell's editable command buffer. Nil for non-buffer messages.
    let text: String?
    /// Cursor offset within `text`. Byte offset for bash (READLINE_POINT), character offset for zsh.
    let cursor: Int?
    /// Which shell is sending the message.
    let shell: ShellType?
    /// Bundle identifier of the terminal app hosting this shell session.
    let terminal: String?
    /// PID of the shell process. Used to correlate socket connections with terminal windows.
    let pid: Int32?
    /// Terminal cursor row (1-based, from CSI 6n or shell LINES). Used for overlay positioning.
    let row: Int?
    /// Terminal cursor column (1-based). Used for overlay positioning.
    let col: Int?
}

/// Resolved snapshot of a terminal shell session's editable state.
///
/// This is the terminal-world analogue of `FocusedInputSnapshot`: it carries everything needed to
/// build a `SuggestionRequest` and position the ghost text overlay, but sourced from shell hooks
/// instead of Accessibility attributes.
struct TerminalFocusSnapshot: Equatable, Sendable {
    /// The full command buffer text (e.g. "git commit -m ").
    let commandBuffer: String
    /// Cursor offset within `commandBuffer`.
    /// For zsh this is a character offset; for bash a byte offset (converted to character offset
    /// by `TerminalFocusAdapter` before feeding into the suggestion pipeline).
    let cursorOffset: Int
    /// Which shell produced this snapshot.
    let shellType: ShellType
    /// Bundle identifier of the hosting terminal app (e.g. "com.mitchellh.ghostty").
    let terminalBundleIdentifier: String
    /// PID of the shell process.
    let shellPid: Int32
    /// AX-derived frame of the terminal window. Terminals expose `AXWindow`/`AXFrame` even though
    /// their text content is opaque.
    let terminalWindowFrame: CGRect?
    /// Estimated cursor screen position derived from the shell-reported row/column and terminal
    /// cell metrics. Nil when geometry cannot be estimated.
    let estimatedCursorPosition: CGPoint?
    /// Terminal cursor row (1-based).
    let cursorRow: Int?
    /// Terminal cursor column (1-based).
    let cursorColumn: Int?
    /// When this snapshot was created.
    let timestamp: Date

    /// Text before the cursor — the "preceding text" that the suggestion engine uses as context.
    var precedingText: String {
        guard cursorOffset >= 0, cursorOffset <= commandBuffer.count else {
            return commandBuffer
        }
        let index = commandBuffer.index(
            commandBuffer.startIndex,
            offsetBy: cursorOffset,
            limitedBy: commandBuffer.endIndex
        ) ?? commandBuffer.endIndex
        return String(commandBuffer[..<index])
    }

    /// Text after the cursor.
    var trailingText: String {
        guard cursorOffset >= 0, cursorOffset <= commandBuffer.count else {
            return ""
        }
        let index = commandBuffer.index(
            commandBuffer.startIndex,
            offsetBy: cursorOffset,
            limitedBy: commandBuffer.endIndex
        ) ?? commandBuffer.endIndex
        return String(commandBuffer[index...])
    }
}

/// Tracks the lifecycle of one shell hook connection.
///
/// The integration service maintains one `TerminalSession` per connected shell process. Sessions
/// are keyed by PID and expire when the socket disconnects or a heartbeat timeout fires.
struct TerminalSession: Equatable, Sendable {
    let shellPid: Int32
    let shellType: ShellType
    let terminalBundleIdentifier: String
    let connectedAt: Date
    var lastMessageAt: Date
    var latestSnapshot: TerminalFocusSnapshot?
}
