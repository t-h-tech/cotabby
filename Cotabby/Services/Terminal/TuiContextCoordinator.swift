import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Drives the Claude Code TUI pipeline: detect the situation, take a debounced screenshot of
/// the prompt region, OCR it via `TuiContextReader`, and inject the result into the focus
/// model so the existing suggestion coordinator can produce ghost text the same way it does
/// for shell-integration data.
///
/// **Why this lives as a separate coordinator** (vs. extending `TerminalIntegrationService`):
/// shell integration is sourced from cooperative shell hooks, while the TUI path is sourced
/// from screen pixels. They share `FocusedInputSnapshot` but nothing else — different
/// permissions (Screen Recording vs. Accessibility), different trigger model (push vs. poll),
/// different cancellation rules. Forking the service would have leaked one path's quirks into
/// the other; a dedicated coordinator keeps each contained.
///
/// **Capture and OCR are injected.** This file does not call ScreenCaptureKit directly. The
/// `captureProvider` closure is supplied at construction time by `CotabbyAppEnvironment`, which
/// already owns the screenshot service. The benefit is that the coordinator's logic
/// (debounce, classification, focus injection) stays unit-testable with a stub closure.
@MainActor
final class TuiContextCoordinator {
    /// Single async closure that owns BOTH window discovery and region capture. Bundling them
    /// avoids the sync/async mismatch of a separate `windowFrame()` lookup — ScreenCaptureKit's
    /// shareable-content callback is async-only, so any cached-frame design would either lag a
    /// frame or duplicate the SCK call. Returning nil from the closure means "not ready right
    /// now" (window hidden, permission missing, etc.); the coordinator backs off without error.
    typealias CaptureSession = @MainActor () async throws -> CaptureResult?

    struct CaptureResult {
        let descriptor: TerminalWindowDescriptor
        /// The screen-space CG rect the image actually covers. Equal to the window frame for
        /// dedicated terminals; constrained to the focused pane (AX element frame) in
        /// embedded-terminal hosts, where full-window OCR would read editor chrome. All OCR
        /// box → screen mapping must use THIS rect, never the window frame.
        let region: CGRect
        let image: CGImage
    }

    typealias FrontmostBundleProvider = @MainActor () -> String?
    typealias TerminalTitleProvider = @MainActor () -> String?
    typealias ForegroundProcessProvider = @MainActor () -> [String]
    typealias FocusChangeSequenceProvider = @MainActor () -> UInt64

    /// Minimum frame info the coordinator needs about the focused terminal to crop a prompt
    /// region: the screen-space window rect, the host process PID, the rendered bundle id, and
    /// a human-readable name for the menu bar / overlay.
    struct TerminalWindowDescriptor: Equatable {
        let windowFrame: CGRect
        let pid: Int32
        let bundleIdentifier: String
        let applicationName: String
    }

    private let reader: TuiContextReader
    private let captureSession: CaptureSession
    private let frontmostBundleProvider: FrontmostBundleProvider
    private let terminalTitleProvider: TerminalTitleProvider
    private let foregroundProcessProvider: ForegroundProcessProvider
    private let focusChangeSequenceProvider: FocusChangeSequenceProvider
    private let isEnabled: () -> Bool
    /// True while the frontmost app's shell hook is actively reporting buffers (a report landed
    /// within the last couple of seconds). A fresh shell means the user is typing AT THE PROMPT
    /// — the shell-prompt source owns input there (Sub-plan D precedence), and the TUI path
    /// must stand down even when `claude` is alive in ANOTHER tab/window of the same app.
    private let isShellActivelyReporting: () -> Bool
    private let injectSnapshot: (FocusedInputSnapshot) -> Void
    private let clearInjection: () -> Void

    /// Debounce window between keystroke triggers. Two snappy keystrokes in a row coalesce
    /// into one capture+OCR pass so the latency budget is paid once per burst, not once per
    /// keystroke.
    private static let debounceInterval: TimeInterval = 0.18

    /// Fraction of the terminal window's bottom band used as the crop region. Claude Code's
    /// input box renders near the bottom inside a small bordered rectangle; capturing the
    /// bottom 22% of the window covers it with margin without blowing the OCR latency budget
    /// on irrelevant scrollback. Tunable here so the spike gate (C.2) can lower this as
    /// accuracy stabilizes.
    private static let promptRegionHeightFraction: CGFloat = 0.22

    /// Heartbeat poll period. Keystrokes are the primary trigger, but CGEvent taps cannot see
    /// synthetic/automated input (TCC withholds cross-process posts from taps), and Claude Code
    /// also redraws its input box without any keystroke (history recall, paste, streaming).
    /// A ~1s heartbeat keeps the OCR snapshot live while Claude Code is foreground. Outside
    /// Claude Code each tick short-circuits on the bundle-id check, so the idle cost is nil.
    private static let heartbeatInterval: TimeInterval = 1.0

    private var debounceTask: Task<Void, Never>?
    private var inflightTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// True between our own `injectSnapshot` and the matching `clearInjection`. `clearInjection`
    /// is shared with the shell-integration path, so calling it when the SHELL owns the current
    /// injection would tear down a healthy shell snapshot on every keystroke at a bare prompt
    /// (and flap `isTerminalMode`). Only clear what we set.
    private var hasInjectedSnapshot = false

    init(
        reader: TuiContextReader = TuiContextReader(),
        captureSession: @escaping CaptureSession,
        frontmostBundleProvider: @escaping FrontmostBundleProvider,
        terminalTitleProvider: @escaping TerminalTitleProvider,
        foregroundProcessProvider: @escaping ForegroundProcessProvider,
        focusChangeSequenceProvider: @escaping FocusChangeSequenceProvider,
        isEnabled: @escaping () -> Bool,
        isShellActivelyReporting: @escaping () -> Bool = { false },
        injectSnapshot: @escaping (FocusedInputSnapshot) -> Void,
        clearInjection: @escaping () -> Void
    ) {
        self.reader = reader
        self.captureSession = captureSession
        self.frontmostBundleProvider = frontmostBundleProvider
        self.terminalTitleProvider = terminalTitleProvider
        self.foregroundProcessProvider = foregroundProcessProvider
        self.focusChangeSequenceProvider = focusChangeSequenceProvider
        self.isEnabled = isEnabled
        self.isShellActivelyReporting = isShellActivelyReporting
        self.injectSnapshot = injectSnapshot
        self.clearInjection = clearInjection
    }

    deinit {
        // Kept at debug: a deinit during app lifetime means the owner dropped the coordinator
        // and the entire TUI path silently died — exactly the bug AppDelegate retention fixed.
        CotabbyLogger.app.debug("TuiContextCoordinator deinit — TUI path stops with it")
        debounceTask?.cancel()
        inflightTask?.cancel()
        heartbeatTask?.cancel()
    }

    /// Starts the periodic Claude Code check. Idempotent; called once from
    /// `CotabbyAppEnvironment` after wiring. A tick that does NOT classify as Claude Code
    /// clears the injection ONLY when this coordinator holds it (`hasInjectedSnapshot`) —
    /// that is the keystroke-free recovery path after the TUI exits (no keystroke means
    /// `keystrokeObserved`'s cancel never runs, and the badge would otherwise stay on
    /// TuiOCR forever). Ticks where the TUI never injected stay pure no-ops so the 1 Hz
    /// loop cannot race the shell hook's own snapshot injections at the bare prompt.
    func startHeartbeat() {
        CotabbyLogger.app.info("TUI heartbeat starting (already running: \(heartbeatTask != nil))")
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            // Transition-logged (not per-tick) so the JSONL shows exactly where the chain
            // stops — disabled gate vs. classification vs. capture — without 1 Hz spam.
            var lastLoggedState = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self else { continue }
                let state: String
                if !self.isEnabled() {
                    state = "disabled (experiment off or Screen Recording missing)"
                } else {
                    let classification = TuiSessionDetector.classification(
                        bundleIdentifier: self.frontmostBundleProvider(),
                        terminalAccessibilityTitle: self.terminalTitleProvider(),
                        foregroundProcessNames: { [provider = self.foregroundProcessProvider] in provider() }
                    )
                    if classification == .claudeCode, self.isShellActivelyReporting() {
                        // Same yield as `keystrokeObserved`: a live prompt session owns input.
                        state = "classification=claudeCode (yielding to active shell)"
                    } else {
                        state = "classification=\(classification)"
                        if classification == .claudeCode {
                            self.scheduleRefresh()
                        } else if self.hasInjectedSnapshot {
                            // Claude Code left the frontmost window (TUI exited, or the user
                            // switched apps) and no keystroke will arrive to run
                            // `keystrokeObserved`'s cancel. Safe against the shell path twice
                            // over: `cancelPending` only clears what THIS coordinator
                            // injected, and the environment's `clearInjection` closure
                            // re-verifies the live snapshot is TUI-owned before tearing down.
                            self.cancelPending()
                        }
                    }
                }
                if state != lastLoggedState {
                    CotabbyLogger.app.debug("TUI heartbeat: \(state)")
                    lastLoggedState = state
                }
            }
        }
    }

    /// Call from the input monitor's listen-only observer for every keystroke. The coordinator
    /// decides whether the situation is "Claude Code TUI focused + experiment on" and
    /// schedules a debounced OCR refresh accordingly. Mismatched situations are a fast no-op.
    func keystrokeObserved() {
        guard isEnabled() else { return }

        let classification = TuiSessionDetector.classification(
            bundleIdentifier: frontmostBundleProvider(),
            terminalAccessibilityTitle: terminalTitleProvider(),
            foregroundProcessNames: { [foregroundProcessProvider] in foregroundProcessProvider() }
        )

        guard classification == .claudeCode else {
            // Stepped out of Claude Code (or into a non-terminal). Cancel any pending capture
            // so a stale snapshot doesn't land after the user has already moved on.
            cancelPending()
            return
        }

        // Classification is app-wide (process tree), so `claude` running in ANOTHER tab of the
        // same app still classifies. A shell that is actively reporting means THIS keystroke
        // reached a bare prompt — the shell-prompt source owns input; stand down and release
        // any injected TUI snapshot so AX/shell snapshots regain focus.
        if isShellActivelyReporting() {
            cancelPending()
            return
        }

        scheduleRefresh()
    }

    /// Cancel any in-flight or pending capture. Call from the focus-session boundary
    /// (`onSessionChange` analogue) so a fast app-switch doesn't deliver yesterday's prompt.
    /// The injection is released only if this coordinator was the one holding it — see
    /// `hasInjectedSnapshot`.
    func cancelPending() {
        debounceTask?.cancel()
        debounceTask = nil
        inflightTask?.cancel()
        inflightTask = nil
        if hasInjectedSnapshot {
            hasInjectedSnapshot = false
            clearInjection()
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.startCapture()
        }
    }

    private func startCapture() {
        inflightTask?.cancel()
        inflightTask = Task { [weak self] in
            await self?.performCapture()
        }
    }

    private func performCapture() async {
        let result: CaptureResult?
        do {
            result = try await captureSession()
        } catch {
            CotabbyLogger.app.warning("TuiContextCoordinator capture failed: \(error.localizedDescription)")
            return
        }
        guard let result else {
            // nil is the "not ready" contract (frontmost changed, window hidden, SCK lookup
            // empty) — log it, otherwise this is an invisible dead end in the TUI chain.
            CotabbyLogger.app.debug("TUI capture returned nil (frontmost/window unavailable)")
            return
        }
        guard !Task.isCancelled else { return }

        let reading: TuiContextReader.PromptReading
        do {
            reading = try await reader.read(regionImage: result.image)
        } catch {
            CotabbyLogger.app.warning("TuiContextCoordinator OCR failed: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }

        // Per-WINDOW arbiter: process-tree classification is app-wide, so a bare prompt in
        // window B still classifies while `claude` runs in window A. Only the captured screen
        // itself can say which window this is — no fingerprint, no injection. Deliberately NOT
        // clearing here: a live shell suggestion may be on screen, and the keystroke-time
        // staleness/yield guards own teardown.
        guard reading.looksLikeClaudeCode else {
            CotabbyLogger.app.debug("TUI capture lacks Claude Code fingerprint; not injecting")
            return
        }

        // Anchor geometry to the OCR'd input line. Vision's boxes are normalized with a
        // BOTTOM-LEFT origin relative to the captured image; the capture rect is CG
        // (TOP-LEFT origin) screen coordinates — so y maps via (1 - maxY).
        let captureRect = result.region
        let cellMetrics = TerminalGeometryResolver.defaultCellMetrics
        let lineRectCG: CGRect
        if let box = reading.promptLineBox {
            lineRectCG = CGRect(
                x: captureRect.minX + box.minX * captureRect.width,
                y: captureRect.minY + (1 - box.maxY) * captureRect.height,
                width: box.width * captureRect.width,
                height: max(box.height * captureRect.height, cellMetrics.cellHeight)
            )
        } else {
            // No line geometry from OCR: assume the bottom band, the common spot for a
            // long-running session.
            lineRectCG = CGRect(
                x: captureRect.minX,
                y: captureRect.maxY - cellMetrics.cellHeight * 3,
                width: captureRect.width,
                height: cellMetrics.cellHeight
            )
        }
        // Caret: one cell past the end of the recognized text on that line.
        let caretCG = CGRect(
            x: min(lineRectCG.maxX + 4, captureRect.maxX - cellMetrics.cellWidth),
            y: lineRectCG.minY,
            width: cellMetrics.cellWidth,
            height: lineRectCG.height
        )
        // The input frame spans the FULL pane width at the line's height — the OCR'd line box
        // ends at the last typed character, and handing that to the inline layout leaves it
        // ~zero horizontal room, wrapping the ghost text into a one-word-wide column.
        let inputLineCG = CGRect(
            x: captureRect.minX,
            y: lineRectCG.minY,
            width: captureRect.width,
            height: lineRectCG.height
        )
        // The overlay consumes caretRect/inputFrameRect as AppKit bottom-left screen points
        // with NO conversion of its own (see OverlayController/MirrorOverlayLayout) — the AX
        // pipeline converts at the source via AXHelper, and so must we.
        let caretRect = AXHelper.cocoaRect(fromAccessibilityRect: caretCG)
        let region = AXHelper.cocoaRect(fromAccessibilityRect: inputLineCG)
        let snapshot = TuiFocusAdapter.adapt(
            reading: reading,
            terminal: .init(
                bundleIdentifier: result.descriptor.bundleIdentifier,
                applicationName: result.descriptor.applicationName,
                pid: result.descriptor.pid
            ),
            promptCaretRect: caretRect,
            inputFrameRect: region,
            focusChangeSequence: focusChangeSequenceProvider()
        )
        injectSnapshot(snapshot)
        hasInjectedSnapshot = true
        // Success marker for diagnostics and the E2E harness: "did the TUI path actually
        // produce a snapshot?" is otherwise invisible (failures log above, success didn't).
        CotabbyLogger.app.debug(
            "ClaudeCodeTuiInput snapshot injected: chars=\(reading.promptText.count) ocrMs=\(Int(reading.latencyMilliseconds))"
        )
    }

    /// Crop the bottom band where Claude Code's prompt box sits. The fraction is conservative
    /// (margin > tightness) so a slight border-color change does not eat the editable line.
    /// Exposed `static` so the AppEnvironment's `captureSession` closure can compute the same
    /// region the coordinator uses when interpreting the result.
    static func promptRegion(for windowFrame: CGRect) -> CGRect {
        let bandHeight = max(60, windowFrame.height * promptRegionHeightFraction)
        // `windowFrame` comes from ScreenCaptureKit in CG (top-left origin) coordinates, so
        // the BOTTOM band starts at maxY - height. Using minY here captured the title bar and
        // Claude Code's header instead of its input box.
        return CGRect(
            x: windowFrame.minX,
            y: windowFrame.maxY - bandHeight,
            width: windowFrame.width,
            height: bandHeight
        )
    }

    func promptRegion(for windowFrame: CGRect) -> CGRect {
        Self.promptRegion(for: windowFrame)
    }

}
