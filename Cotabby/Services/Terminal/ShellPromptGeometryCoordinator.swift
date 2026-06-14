import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Owns the OCR prompt anchors that position shell-surface ghost text. One debounced
/// capture+OCR pass per prompt builds a `TerminalPromptAnchor` (via the pure
/// `TerminalPromptAnchorResolver`); every keystroke report then resolves the caret
/// arithmetically from the cached anchor — synchronous, no per-keystroke OCR.
///
/// **Why a separate coordinator** (vs. folding into `TerminalIntegrationService` or
/// `TuiContextCoordinator`): the integration service is a socket server with no screen
/// concerns, and the TUI coordinator is push-vs-poll and permissioned differently (its OCR
/// must run continuously while a TUI owns the tty; this one runs once per prompt). Sharing
/// either would leak one path's trigger model into the other — the same reasoning as the
/// TUI coordinator's own header.
///
/// **Anchor lifecycle.** Anchors are keyed by shell pid. They die on: window move/resize,
/// age-out (`TerminalPromptAnchorResolver.defaultMaxAge` — scroll is unobservable), a fresh
/// prompt (empty-buffer report after a typed-buffer anchor: Enter moved the prompt down),
/// caret-out-of-window, or session teardown. A failed match never anchors — a wrong anchor
/// paints ghost text over arbitrary screen content, which is strictly worse than the overlay
/// staying hidden until the next OCR pass lands.
@MainActor
final class ShellPromptGeometryCoordinator {

    /// One capture of the terminal's window/pane. `region` is the CG screen rect the image
    /// covers (the focused pane in embedded hosts, the whole window otherwise); all OCR box
    /// mapping uses THIS rect. Nil means "not ready" (terminal not frontmost, window hidden,
    /// Screen Recording missing) — the coordinator backs off without error.
    struct CaptureResult {
        let region: CGRect
        let windowFrame: CGRect
        let image: CGImage
    }

    typealias CaptureSession = @MainActor (TerminalFocusSnapshot) async throws -> CaptureResult?

    /// Caret geometry for one buffer report, in AppKit bottom-left screen coordinates —
    /// ready for `FocusedInputSnapshot` with no further conversion.
    struct ResolvedPromptGeometry: Equatable {
        let windowFrame: CGRect
        let caretRect: CGRect
        let inputLineRect: CGRect
        let cellWidth: CGFloat
    }

    private let captureSession: CaptureSession
    private let extractor: any ScreenTextExtracting
    /// Current CG window frame for anchor validation. Wraps the same AX lookup
    /// `TerminalGeometryResolver` uses; injected so tests can stub it.
    private let windowFrameProvider: @MainActor (TerminalFocusSnapshot) -> CGRect?
    private let isEnabled: @MainActor () -> Bool
    /// Fired after a NEW anchor lands so the environment can re-enrich and re-inject the
    /// latest snapshot — that re-injection is what snaps the ghost from hidden to positioned.
    var onAnchorResolved: (@MainActor (Int32) -> Void)?

    private var anchors: [Int32: TerminalPromptAnchor] = [:]
    private var refreshTask: Task<Void, Never>?
    private var inflightPid: Int32?
    private var consecutiveMisses: [Int32: Int] = [:]
    private var backoffUntil: [Int32: Date] = [:]

    private static let debounceInterval: TimeInterval = 0.25
    private static let missBackoffThreshold = 3
    private static let missBackoffInterval: TimeInterval = 2.0

    init(
        captureSession: @escaping CaptureSession,
        extractor: any ScreenTextExtracting = ScreenTextExtractor(),
        windowFrameProvider: @escaping @MainActor (TerminalFocusSnapshot) -> CGRect?,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        self.captureSession = captureSession
        self.extractor = extractor
        self.windowFrameProvider = windowFrameProvider
        self.isEnabled = isEnabled
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Synchronous lookup

    /// Caret geometry for this report from the cached anchor, already converted to AppKit
    /// coordinates. Nil when no valid anchor exists — the caller falls back to legacy
    /// enrichment (whose contract is now "no caret → overlay hidden", never a guess).
    func geometry(for snapshot: TerminalFocusSnapshot) -> ResolvedPromptGeometry? {
        guard let anchor = anchors[snapshot.shellPid] else { return nil }
        guard TerminalPromptAnchorResolver.isValid(
            anchor,
            currentWindowFrame: windowFrameProvider(snapshot),
            cursorOffset: snapshot.cursorOffset,
            now: Date()
        ) else {
            anchors[snapshot.shellPid] = nil
            return nil
        }

        let caretCG = TerminalPromptAnchorResolver.caretRect(
            cursorOffset: snapshot.cursorOffset, anchor: anchor
        )
        let lineCG = TerminalPromptAnchorResolver.inputLineRect(
            cursorOffset: snapshot.cursorOffset, anchor: anchor
        )
        // Pure helpers stay CG (top-left); the overlay consumes AppKit bottom-left points with
        // no conversion of its own — convert once here, at the service boundary, same as
        // TerminalGeometryResolver.
        return ResolvedPromptGeometry(
            windowFrame: AXHelper.cocoaRect(fromAccessibilityRect: anchor.windowFrame),
            caretRect: AXHelper.cocoaRect(fromAccessibilityRect: caretCG),
            inputLineRect: AXHelper.cocoaRect(fromAccessibilityRect: lineCG),
            cellWidth: anchor.cellWidth
        )
    }

    // MARK: - Refresh scheduling

    /// Call on EVERY buffer report. Decides whether an OCR refresh is needed and schedules a
    /// debounced capture. Cheap no-op when a valid anchor already serves this shell.
    func snapshotReported(_ snapshot: TerminalFocusSnapshot) {
        guard isEnabled() else { return }

        let pid = snapshot.shellPid
        let bufferIsEmpty = snapshot.commandBuffer
            .trimmingCharacters(in: .whitespaces).isEmpty

        if let anchor = anchors[pid] {
            let valid = TerminalPromptAnchorResolver.isValid(
                anchor,
                currentWindowFrame: windowFrameProvider(snapshot),
                cursorOffset: snapshot.cursorOffset,
                now: Date()
            )
            // A fresh prompt after Enter: the shell reports an EMPTY buffer while the anchor
            // was built against typed text — the prompt has moved down at least one row, so
            // the old anchor is WRONG and must go immediately.
            let newPrompt = bufferIsEmpty && !anchor.isLowConfidence
            // A low-confidence (empty-buffer) anchor upgrades as soon as real text exists to
            // match against — but it keeps SERVING until the replacement lands: it is
            // approximately right (one cell of drift at most), and nilling it up front left
            // the ghost dark whenever the upgrade OCR missed (observed: fast typing burst,
            // 4-line OCR read, no needle match — anchor gone, nothing to fall back to).
            let upgrade = !bufferIsEmpty && anchor.isLowConfidence
            if valid && !newPrompt && !upgrade {
                return
            }
            if !valid || newPrompt {
                anchors[pid] = nil
            }
        }

        if let until = backoffUntil[pid], Date() < until { return }
        scheduleRefresh(for: snapshot)
    }

    func invalidate(shellPid: Int32) {
        anchors[shellPid] = nil
        consecutiveMisses[shellPid] = nil
        backoffUntil[shellPid] = nil
    }

    func invalidateAll() {
        anchors.removeAll()
        consecutiveMisses.removeAll()
        backoffUntil.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        inflightPid = nil
    }

    /// Drop state for shells that no longer have a live session.
    func prune(keeping livePids: some Collection<Int32>) {
        let keep = Set(livePids)
        anchors = anchors.filter { keep.contains($0.key) }
        consecutiveMisses = consecutiveMisses.filter { keep.contains($0.key) }
        backoffUntil = backoffUntil.filter { keep.contains($0.key) }
    }

    // MARK: - Private

    private func scheduleRefresh(for snapshot: TerminalFocusSnapshot) {
        // One in-flight refresh at a time; a newer report for the SAME shell just replaces the
        // pending debounce (the capture reads the latest screen anyway). A report for another
        // shell while one is in flight waits for its own next report — at one OCR per prompt
        // the contention window is tiny.
        if inflightPid == snapshot.shellPid { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performRefresh(for: snapshot)
        }
    }

    private func performRefresh(for snapshot: TerminalFocusSnapshot) async {
        guard inflightPid == nil else { return }
        inflightPid = snapshot.shellPid
        defer { inflightPid = nil }

        let result: CaptureResult?
        do {
            result = try await captureSession(snapshot)
        } catch {
            CotabbyLogger.app.debug("Shell prompt anchor capture failed: \(error.localizedDescription)")
            return
        }
        guard let result else { return }
        guard !Task.isCancelled else { return }

        let extracted: ExtractedScreenText
        do {
            extracted = try await extractor.extractText(from: result.image)
        } catch {
            CotabbyLogger.app.debug("Shell prompt anchor OCR failed: \(error.localizedDescription)")
            registerMiss(for: snapshot.shellPid)
            return
        }
        guard !Task.isCancelled else { return }

        // The user may have kept typing during the debounce+OCR window, so this buffer can be
        // stale — that is fine: matching keys on the buffer's FIRST characters, and appending
        // never moves the buffer's start. (Backspacing below the prefix is a miss; the next
        // report retries.)
        guard let match = TerminalPromptAnchorResolver.match(
            buffer: snapshot.commandBuffer,
            lines: extracted.lines
        ) else {
            registerMiss(for: snapshot.shellPid)
            let bufferPrefix = String(snapshot.commandBuffer.prefix(16))
            CotabbyLogger.app.debug(
                "Shell prompt anchor miss (no line matched): pid=\(snapshot.shellPid) buffer=\(bufferPrefix) lines=\(extracted.lines.count)"
            )
            return
        }
        guard let anchor = TerminalPromptAnchorResolver.makeAnchor(
            match: match,
            lines: extracted.lines,
            geometry: .init(region: result.region, windowFrame: result.windowFrame),
            shellPid: snapshot.shellPid,
            now: Date()
        ) else {
            registerMiss(for: snapshot.shellPid)
            CotabbyLogger.app.debug(
                "Shell prompt anchor miss (implausible line metrics): pid=\(snapshot.shellPid) lineIndex=\(match.lineIndex)"
            )
            return
        }

        consecutiveMisses[snapshot.shellPid] = nil
        backoffUntil[snapshot.shellPid] = nil
        anchors[snapshot.shellPid] = anchor
        let cellLabel = String(format: "%.1f", anchor.cellWidth)
        CotabbyLogger.app.debug(
            "Shell prompt anchor set: pid=\(snapshot.shellPid) cell=\(cellLabel) lowConfidence=\(anchor.isLowConfidence)"
        )
        onAnchorResolved?(snapshot.shellPid)
    }

    private func registerMiss(for pid: Int32) {
        let misses = (consecutiveMisses[pid] ?? 0) + 1
        consecutiveMisses[pid] = misses
        if misses >= Self.missBackoffThreshold {
            backoffUntil[pid] = Date().addingTimeInterval(Self.missBackoffInterval)
            consecutiveMisses[pid] = 0
        }
    }
}
