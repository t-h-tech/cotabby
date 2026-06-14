import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Spike-quality reader that extracts the contents of a Claude Code (or similar TUI) prompt box
/// from a screenshot of its terminal window. The reader does not own screen capture itself —
/// callers pass in a `CGImage` of the *terminal window's prompt region* so this type can stay
/// focused on the OCR pipeline and on producing a value the suggestion coordinator can consume
/// without knowing anything about Vision or screen-recording permission.
///
/// **Spike posture.** Sub-plan C.2 in
/// `docs/plan-terminal-claude-code-and-per-app-shortcuts.md` calls for a go/no-go gate before
/// investing in the rest of the TUI path. This file is intentionally minimal — it measures
/// latency, records confidence-ish signals, and otherwise relays the OCR result. If the spike
/// fails the latency/accuracy budget the team can swap this for one of the C.6 alternatives
/// (Claude Code native hook, iTerm2 scripting, etc.) without touching the focus adapter or the
/// pipeline wiring above.
///
/// **Why the region is the caller's responsibility.** Locating the prompt box requires either
/// the terminal window's AX frame (different per terminal) or a fingerprint pass over a full
/// window screenshot. Both of those concerns belong upstream so this reader can be unit-tested
/// against fixture screenshots without dragging in ScreenCaptureKit.
struct TuiContextReader {
    /// What a single read produced. The fields are deliberately small — the suggestion pipeline
    /// only needs the line text and an estimated cursor position; richer OCR metadata is logged
    /// for the latency/accuracy gate but does not flow into the suggestion request.
    struct PromptReading: Equatable, Sendable {
        /// The cleaned prompt text as the user has typed it so far.
        let promptText: String
        /// Cursor estimate within `promptText`. Vision does not surface a caret, so this is set
        /// to the end of `promptText` by default — Claude Code only ever takes input at the end
        /// of the editable line, which makes that the correct fallback. Future passes can refine
        /// this from layout hints (right-aligned cursor glyph, blink frame, etc.).
        let estimatedCursorOffset: Int
        /// Total OCR + hygiene wall time. Used by the spike gate to decide whether the path is
        /// viable; not surfaced to the suggestion coordinator.
        let latencyMilliseconds: Int
        /// Number of recognized lines before hygiene compaction. A read with `recognizedLineCount
        /// == 0` is the canonical "OCR found nothing" signal even when `promptText` is empty.
        let recognizedLineCount: Int
        /// Vision-normalized bounding box of the matched input line within the captured image
        /// ([0,1], bottom-left origin). Claude Code anchors its input box under the conversation
        /// content, so with a short chat the line sits near the TOP of the window — the overlay
        /// must follow the line, not assume a fixed band. Nil when OCR produced no per-line
        /// geometry (legacy extractors, empty reads); the coordinator then falls back to a
        /// bottom-of-window estimate.
        var promptLineBox: CGRect?
        /// Whether the captured screen actually shows Claude Code's UI (banner / status-line
        /// markers). Detection by process tree is APP-wide, so `claude` alive in another
        /// tab/window classifies a bare shell prompt too — this is the per-WINDOW arbiter the
        /// coordinator checks before injecting (plan heuristic C.1-3, OCR fingerprint).
        var looksLikeClaudeCode: Bool = true
    }

    enum ReadError: LocalizedError {
        case extractorFailed(String)
        case emptyExtraction

        var errorDescription: String? {
            switch self {
            case let .extractorFailed(message):
                return "TUI OCR failed: \(message)"
            case .emptyExtraction:
                return "TUI OCR returned no text."
            }
        }
    }

    private let extractor: any ScreenTextExtracting

    init(extractor: any ScreenTextExtracting = ScreenTextExtractor()) {
        self.extractor = extractor
    }

    /// Read one prompt snapshot from `regionImage`.
    ///
    /// `regionImage` should already be cropped to the Claude Code input box (the small bordered
    /// rectangle at the bottom of the terminal window). Whole-window screenshots will OCR
    /// correctly but burn the latency budget and produce noisy lines that the hygiene pass can
    /// only partly clean up. The caller is responsible for the crop so this reader can be
    /// unit-tested against fixed-size fixtures.
    func read(regionImage: CGImage) async throws -> PromptReading {
        let startedAt = Date()
        let extracted: ExtractedScreenText
        do {
            extracted = try await extractor.extractText(from: regionImage)
        } catch let ScreenTextExtractionError.ocrFailed(message) {
            throw ReadError.extractorFailed(message)
        } catch ScreenTextExtractionError.noRecognizedText {
            // The OCR found nothing — produce an empty reading so the caller can distinguish
            // "TUI prompt is empty" from a hard failure without try/catch noise in the path.
            // An empty screen is definitionally NOT Claude Code (its chrome always renders),
            // so the fingerprint must be false here or the per-window arbiter would inject an
            // empty snapshot with fabricated geometry over any cleared/blank window.
            return PromptReading(
                promptText: "",
                estimatedCursorOffset: 0,
                latencyMilliseconds: elapsedMilliseconds(since: startedAt),
                recognizedLineCount: 0,
                looksLikeClaudeCode: false
            )
        }

        // Prefer geometry-aware matching: with per-line boxes the BOTTOM-MOST glyph line is
        // unambiguous (menus with the same glyph render above the input box). Fall back to the
        // text-only heuristic when the extractor produced no line geometry.
        let extraction = promptLine(in: extracted)
        let cursor = extraction.text.count

        return PromptReading(
            promptText: extraction.text,
            estimatedCursorOffset: cursor,
            latencyMilliseconds: elapsedMilliseconds(since: startedAt),
            recognizedLineCount: extracted.lineCount,
            promptLineBox: extraction.box,
            looksLikeClaudeCode: Self.containsClaudeCodeFingerprint(extracted.text)
        )
    }

    /// Markers Claude Code's UI always renders somewhere on screen: the banner ("Claude Code
    /// vX"), the status line ("Opus 4.8 (1M context)" — matched loosely on "context)" so model
    /// and window-size changes don't break it), and the streaming hint. A bare shell prompt
    /// shows none of these even when `claude` is alive in another tab of the same app.
    static let claudeCodeScreenMarkers: [String] = [
        "Claude Code",
        "context)",
        "esc to interrupt"
    ]

    static func containsClaudeCodeFingerprint(_ screenText: String) -> Bool {
        Self.claudeCodeScreenMarkers.contains { screenText.localizedCaseInsensitiveContains($0) }
    }

    /// Prompt glyphs Claude Code renders at the start of its editable line, in the variants
    /// Vision actually returns for them across terminals/fonts ("❯" is frequently read as "›",
    /// ">", or even ")"). Matching any of these marks a line as a candidate input line. The
    /// same glyph also marks menu selections (trust screen, option lists), which is why the
    /// matcher must take the BOTTOM-MOST glyph line — the editable input always renders below
    /// the menus, and the status bar beneath it carries no glyph.
    private static let promptGlyphs: [String] = ["❯", "›", ">", ")"]

    /// Pull the prompt text (and its normalized box, when geometry is available) out of the
    /// OCR result. A Claude Code window contains the banner, the conversation, menus that reuse
    /// the prompt glyph, the bordered input box, and a status bar — so neither "last non-empty
    /// line" (reads the status bar) nor "any glyph line" (reads menus like the trust screen's
    /// "❯ 2. No, exit") is correct. The editable input is the BOTTOM-MOST glyph line: in
    /// Vision's bottom-left-origin boxes that is the matching line with the smallest minY.
    private func promptLine(in extracted: ExtractedScreenText) -> (text: String, box: CGRect?) {
        if !extracted.lines.isEmpty {
            let glyphLines = extracted.lines.filter { line in
                Self.promptGlyphs.contains { line.text.hasPrefix($0) }
            }
            if let input = glyphLines.min(by: { $0.boundingBox.minY < $1.boundingBox.minY }) {
                let glyph = Self.promptGlyphs.first { input.text.hasPrefix($0) } ?? ""
                let text = String(input.text.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces)
                return (text, input.boundingBox)
            }
            // No glyph survived OCR: take the bottom-most line above the status bar — i.e. the
            // second-from-bottom when more than one line exists, else the only line.
            let bottomUp = extracted.lines.sorted { $0.boundingBox.minY < $1.boundingBox.minY }
            if let line = bottomUp.count > 1 ? bottomUp[1] : bottomUp.first {
                return (line.text, line.boundingBox)
            }
        }

        // Geometry-free fallback (legacy extractors / fixtures): last glyph line by text order.
        let lines = extracted.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return ("", nil) }
        for line in lines.reversed() {
            for glyph in Self.promptGlyphs where line.hasPrefix(glyph) {
                return (String(line.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces), nil)
            }
        }
        return (lines[lines.count - 1], nil)
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
