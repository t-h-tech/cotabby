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
        /// Ask Cotabby to accept the currently visible suggestion. Honored only when the app was
        /// launched with `-cotabby-debug` — it exists so the E2E harness can exercise the real
        /// acceptance path (session validation → clipboard paste) without a hardware keystroke,
        /// which CGEvent taps cannot receive from test automation on modern macOS.
        case accept
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
    /// OCR-anchored caret cell (AppKit bottom-left screen coords). When present this is the
    /// authoritative caret — unlike `estimatedCursorPosition` it is calibrated against the
    /// actual on-screen prompt line, not a fixed-inset guess.
    let estimatedCursorRect: CGRect?
    /// The prompt LINE rect (full pane width, one cell tall, AppKit coords). Feeds the overlay's
    /// `inputFrameRect` so ghost text wraps at the pane's right edge and continuation lines
    /// land one row below — handing the whole window frame here makes wraps span the window.
    let promptLineRect: CGRect?
    /// Per-character cell width calibrated from the OCR'd prompt line (`boxWidth / charCount`).
    /// Nil falls back to `TerminalGeometryResolver.defaultCellMetrics`.
    let observedCellWidth: CGFloat?

    init(
        commandBuffer: String,
        cursorOffset: Int,
        shellType: ShellType,
        terminalBundleIdentifier: String,
        shellPid: Int32,
        terminalWindowFrame: CGRect?,
        estimatedCursorPosition: CGPoint?,
        cursorRow: Int?,
        cursorColumn: Int?,
        timestamp: Date,
        estimatedCursorRect: CGRect? = nil,
        promptLineRect: CGRect? = nil,
        observedCellWidth: CGFloat? = nil
    ) {
        self.commandBuffer = commandBuffer
        self.cursorOffset = cursorOffset
        self.shellType = shellType
        self.terminalBundleIdentifier = terminalBundleIdentifier
        self.shellPid = shellPid
        self.terminalWindowFrame = terminalWindowFrame
        self.estimatedCursorPosition = estimatedCursorPosition
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.timestamp = timestamp
        self.estimatedCursorRect = estimatedCursorRect
        self.promptLineRect = promptLineRect
        self.observedCellWidth = observedCellWidth
    }

    /// Copy reflecting text Cotabby itself just pasted at the cursor — the optimistic local
    /// echo. Bracketed paste is INVISIBLE to the shell hooks (they report on real keystrokes
    /// only), so without this the live snapshot goes stale after every acceptance: the
    /// whitespace reconciler reads a pre-paste trailing space and strips legitimate
    /// separators ("git pull" + " origin" → "git pullorigin"), and the post-accept ghost
    /// positions against the pre-paste caret. The shell's next real report overwrites this
    /// with ground truth.
    ///
    /// Offset semantics follow the shell: bash reports BYTE offsets (READLINE_POINT), zsh and
    /// fish report character offsets — the inserted length must advance in the same unit.
    func appendingInsertedText(_ insertedText: String) -> TerminalFocusSnapshot {
        let newBuffer = precedingText + insertedText + trailingText
        let advance: Int
        switch shellType {
        case .bash:
            advance = insertedText.utf8.count
        case .zsh, .fish:
            advance = insertedText.count
        }
        return TerminalFocusSnapshot(
            commandBuffer: newBuffer,
            cursorOffset: cursorOffset + advance,
            shellType: shellType,
            terminalBundleIdentifier: terminalBundleIdentifier,
            shellPid: shellPid,
            terminalWindowFrame: terminalWindowFrame,
            estimatedCursorPosition: estimatedCursorPosition,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            timestamp: Date(),
            estimatedCursorRect: estimatedCursorRect,
            promptLineRect: promptLineRect,
            observedCellWidth: observedCellWidth
        )
    }

    /// Copy with OCR-anchored geometry attached. The environment's snapshot-update closure uses
    /// this so it doesn't hand-copy every field when the prompt anchor resolves.
    func withGeometry(
        windowFrame: CGRect?,
        cursorRect: CGRect,
        promptLineRect: CGRect,
        observedCellWidth: CGFloat
    ) -> TerminalFocusSnapshot {
        TerminalFocusSnapshot(
            commandBuffer: commandBuffer,
            cursorOffset: cursorOffset,
            shellType: shellType,
            terminalBundleIdentifier: terminalBundleIdentifier,
            shellPid: shellPid,
            terminalWindowFrame: windowFrame ?? terminalWindowFrame,
            estimatedCursorPosition: estimatedCursorPosition,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            timestamp: timestamp,
            estimatedCursorRect: cursorRect,
            promptLineRect: promptLineRect,
            observedCellWidth: observedCellWidth
        )
    }

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
    /// Mutable because `exec bash` / `exec fish` replaces the shell IMAGE but keeps the PID —
    /// the session survives the swap and must follow the shell actually reporting.
    var shellType: ShellType
    let terminalBundleIdentifier: String
    let connectedAt: Date
    var lastMessageAt: Date
    var latestSnapshot: TerminalFocusSnapshot?
}
