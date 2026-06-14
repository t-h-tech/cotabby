import CoreGraphics
import Foundation

/// File overview:
/// Pure geometry for positioning ghost text on a shell prompt line. One OCR pass per prompt
/// produces a `TerminalPromptAnchor` (where the prompt line is on screen, how wide a character
/// cell is, where buffer offset 0 starts); every subsequent keystroke derives the caret
/// ARITHMETICALLY from the shell-reported cursor offset — no per-keystroke OCR.
///
/// **Why buffer-anchored matching.** The shell hook tells us the exact buffer text, so the OCR
/// line containing that text IS the prompt line — a far stronger signal than the prompt-glyph
/// heuristics the Claude Code TUI reader needs (it doesn't know the typed text). Ties (same
/// command in scrollback, split panes) resolve to the BOTTOM-MOST candidate, the same rule and
/// rationale as `TuiContextReader.promptLine`.
///
/// **Coordinate space.** Everything here is CG screen space (top-left origin) — rows grow
/// DOWNWARD as +y. `ShellPromptGeometryCoordinator` converts the final rects to AppKit
/// bottom-left points via `AXHelper.cocoaRect` at the service boundary, exactly like
/// `TerminalGeometryResolver` does, so these helpers and their tests stay display-independent.
struct TerminalPromptAnchor: Equatable, Sendable {
    let shellPid: Int32
    /// Terminal window frame (CG screen coords) at capture time. A moved/resized window
    /// invalidates the anchor — see `isValid`.
    let windowFrame: CGRect
    /// The capture region the OCR boxes were normalized against: the focused pane in embedded
    /// hosts, the whole window otherwise. Caret/input-line math is clamped to this rect.
    let paneFrame: CGRect
    /// CG screen rect of the matched prompt line.
    let promptLineRect: CGRect
    /// Calibrated character cell, `lineBoxWidth / lineCharCount`. Self-adjusts to the user's
    /// terminal font/zoom, unlike `TerminalGeometryResolver.defaultCellMetrics`.
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// CG screen x where buffer offset 0 renders (end of the prompt decoration).
    let bufferStartX: CGFloat
    /// Columns available in the pane; wraps the arithmetic caret onto the next row.
    let totalColumns: Int
    /// True when the anchor came from an empty-buffer prompt match (no typed text to anchor
    /// on). Good enough to place the first ghost; the first non-empty report re-anchors.
    let isLowConfidence: Bool
    let capturedAt: Date
}

enum TerminalPromptAnchorResolver {

    struct LineMatch: Equatable {
        let lineIndex: Int
        /// Character index into the matched line's RAW text where the buffer text begins.
        /// `Int.max` flags an empty-buffer match (buffer starts after the line's last char).
        let rawNeedleStartIndex: Int
    }

    /// Sanity bounds for a calibrated cell width (points). Outside this range the OCR line was
    /// mis-segmented (merged columns, icon glyphs) and the anchor would scatter ghost text.
    static let cellWidthRange: ClosedRange<CGFloat> = 4...14
    /// Anchor lifetime. Scroll/clear cannot be observed directly, so anchors self-expire and
    /// the next report re-OCRs. Generous on purpose: typing pauses well over 10 s are normal
    /// mid-command (a 4 s limit caused constant expiry churn), terminals snap back to the
    /// bottom on the next keystroke anyway, and the real displacement events — Enter/new
    /// prompt, window move/resize, caret-out-of-window — have their own explicit triggers.
    static let defaultMaxAge: TimeInterval = 20.0

    private static let needleLength = 24
    private static let shortNeedleLength = 12
    /// Prompt terminators for the empty-buffer match, checked AFTER glyph folding (so `❯`
    /// arrives here as `>`).
    private static let promptTerminators: Set<Character> = [">", "%", "$", "#"]

    // MARK: - Matching

    /// Fold the glyphs Vision routinely confuses for one another, WITHOUT touching
    /// alphanumerics — the buffer text must keep its identity for the match to mean anything.
    /// Collapses whitespace runs so OCR spacing differences don't break `contains`.
    static func normalizeForOcrMatch(_ text: String) -> String {
        normalizedWithRawIndices(text).normalized
    }

    /// Find the OCR line showing the buffer. Empty/whitespace buffer → empty-buffer match on
    /// the bottom-most prompt-terminated line. Returns nil on a genuine miss — callers must
    /// NOT anchor then; a wrong anchor paints ghost text over arbitrary screen content.
    static func match(buffer: String, lines: [RecognizedTextLine]) -> LineMatch? {
        guard !lines.isEmpty else { return nil }

        let trimmedBuffer = buffer.trimmingCharacters(in: .whitespaces)
        guard !trimmedBuffer.isEmpty else {
            return emptyBufferMatch(lines: lines)
        }

        let fullNeedle = normalizeForOcrMatch(String(trimmedBuffer.prefix(needleLength)))
        if let match = bottomMostLineContaining(needle: fullNeedle, lines: lines) {
            return match
        }
        if fullNeedle.count > shortNeedleLength {
            let shortNeedle = normalizeForOcrMatch(String(trimmedBuffer.prefix(shortNeedleLength)))
            return bottomMostLineContaining(needle: shortNeedle, lines: lines)
        }
        return nil
    }

    // MARK: - Anchor construction

    /// The CG screen rects an OCR capture was taken against: `region` is the captured area
    /// the Vision boxes ([0,1], BOTTOM-LEFT origin) normalize to; `windowFrame` is the
    /// terminal window, carried onto the anchor for context.
    struct CaptureGeometry {
        let region: CGRect
        let windowFrame: CGRect
    }

    /// Build an anchor from a match. `geometry.region` is the CG screen rect the OCR boxes
    /// were normalized against (Vision boxes are [0,1] with a BOTTOM-LEFT origin — y maps via
    /// `1 - maxY`, the same flip `TuiContextCoordinator.performCapture` documents).
    static func makeAnchor(
        match: LineMatch,
        lines: [RecognizedTextLine],
        geometry: CaptureGeometry,
        shellPid: Int32,
        now: Date
    ) -> TerminalPromptAnchor? {
        let region = geometry.region
        let windowFrame = geometry.windowFrame
        guard lines.indices.contains(match.lineIndex) else { return nil }
        let line = lines[match.lineIndex]
        let rawCount = line.text.count
        guard rawCount > 0 else { return nil }

        let box = line.boundingBox
        let lineRect = CGRect(
            x: region.minX + box.minX * region.width,
            y: region.minY + (1 - box.maxY) * region.height,
            width: box.width * region.width,
            height: max(box.height * region.height, 12)
        )

        let cellWidth = lineRect.width / CGFloat(rawCount)
        guard cellWidthRange.contains(cellWidth) else { return nil }

        let isEmptyBufferMatch = match.rawNeedleStartIndex == Int.max
        let bufferStartX: CGFloat
        if isEmptyBufferMatch {
            // OCR drops the prompt's trailing space; the buffer starts one cell past the line.
            bufferStartX = lineRect.maxX + cellWidth
        } else {
            bufferStartX = lineRect.minX + CGFloat(match.rawNeedleStartIndex) * cellWidth
        }

        return TerminalPromptAnchor(
            shellPid: shellPid,
            windowFrame: windowFrame,
            paneFrame: region,
            promptLineRect: lineRect,
            cellWidth: cellWidth,
            cellHeight: lineRect.height,
            bufferStartX: bufferStartX,
            totalColumns: max(Int(region.width / cellWidth), 20),
            isLowConfidence: isEmptyBufferMatch,
            capturedAt: now
        )
    }

    // MARK: - Arithmetic caret tracking

    /// Caret cell (CG screen coords) for the current cursor offset. Rows wrap at the pane's
    /// column count and grow DOWNWARD (+y in CG) like the terminal grid does.
    static func caretRect(cursorOffset: Int, anchor: TerminalPromptAnchor) -> CGRect {
        let startColumn = Int(((anchor.bufferStartX - anchor.paneFrame.minX) / anchor.cellWidth).rounded())
        let linear = startColumn + max(cursorOffset, 0)
        let row = linear / anchor.totalColumns
        let column = linear % anchor.totalColumns

        return CGRect(
            x: anchor.paneFrame.minX + CGFloat(column) * anchor.cellWidth,
            y: anchor.promptLineRect.minY + CGFloat(row) * anchor.cellHeight,
            width: anchor.cellWidth,
            height: anchor.cellHeight
        )
    }

    /// The full-width, one-cell-tall input line rect at the caret's CURRENT row. Feeding this
    /// (not the window frame) to the overlay makes ghost text wrap at the pane's right edge
    /// and start continuation lines at the pane's left edge, one row below.
    static func inputLineRect(cursorOffset: Int, anchor: TerminalPromptAnchor) -> CGRect {
        let caret = caretRect(cursorOffset: cursorOffset, anchor: anchor)
        return CGRect(
            x: anchor.paneFrame.minX,
            y: caret.minY,
            width: anchor.paneFrame.width,
            height: anchor.cellHeight
        )
    }

    // MARK: - Validity

    /// An anchor survives only while the window hasn't moved/resized (>1pt), it hasn't aged
    /// out, and the computed caret still lands inside the window. Everything else (scroll,
    /// clear, pane re-layout) is unobservable and covered by the age limit.
    static func isValid(
        _ anchor: TerminalPromptAnchor,
        currentWindowFrame: CGRect?,
        cursorOffset: Int,
        now: Date,
        maxAge: TimeInterval = defaultMaxAge
    ) -> Bool {
        guard now.timeIntervalSince(anchor.capturedAt) <= maxAge else { return false }
        if let frame = currentWindowFrame {
            let delta = max(
                abs(frame.minX - anchor.windowFrame.minX),
                abs(frame.minY - anchor.windowFrame.minY),
                abs(frame.width - anchor.windowFrame.width),
                abs(frame.height - anchor.windowFrame.height)
            )
            guard delta <= 1 else { return false }
        }
        let caret = caretRect(cursorOffset: cursorOffset, anchor: anchor)
        return anchor.windowFrame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: caret.midX, y: caret.midY))
    }

    // MARK: - Private

    private static func emptyBufferMatch(lines: [RecognizedTextLine]) -> LineMatch? {
        // Bottom-most (smallest Vision minY) line ending in a prompt terminator; else
        // bottom-most non-empty line. The prompt is the last thing drawn on a fresh screen.
        let nonEmpty = lines.enumerated().filter {
            !$0.element.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !nonEmpty.isEmpty else { return nil }

        let terminated = nonEmpty.filter { entry in
            guard let last = normalizeForOcrMatch(entry.element.text).last else { return false }
            return promptTerminators.contains(last)
        }
        let pool = terminated.isEmpty ? nonEmpty : terminated
        let bottomMost = pool.min { $0.element.boundingBox.minY < $1.element.boundingBox.minY }
        return bottomMost.map { LineMatch(lineIndex: $0.offset, rawNeedleStartIndex: Int.max) }
    }

    private static func bottomMostLineContaining(
        needle: String,
        lines: [RecognizedTextLine]
    ) -> LineMatch? {
        guard !needle.isEmpty else { return nil }

        // Local struct instead of a 3-member tuple — keeps the "lowest line wins" bookkeeping
        // readable and named at the few use sites below.
        struct Candidate {
            let index: Int
            let rawStart: Int
            let minY: CGFloat
        }
        var best: Candidate?
        for (index, line) in lines.enumerated() {
            let mapped = normalizedWithRawIndices(line.text)
            guard let range = mapped.normalized.range(of: needle) else { continue }
            let normalizedStart = mapped.normalized.distance(
                from: mapped.normalized.startIndex,
                to: range.lowerBound
            )
            guard normalizedStart < mapped.rawIndices.count else { continue }
            let rawStart = mapped.rawIndices[normalizedStart]
            let minY = line.boundingBox.minY
            if best == nil || minY < best!.minY {
                best = Candidate(index: index, rawStart: rawStart, minY: minY)
            }
        }
        return best.map { LineMatch(lineIndex: $0.index, rawNeedleStartIndex: $0.rawStart) }
    }

    /// Normalization that remembers, for every normalized character, the index of the raw
    /// character it came from — the match position must map back to RAW text because cell
    /// width is calibrated against the raw character count.
    private static func normalizedWithRawIndices(_ text: String) -> (normalized: String, rawIndices: [Int]) {
        var normalized = ""
        var rawIndices: [Int] = []
        var previousWasSpace = true   // leading whitespace is dropped (acts like trim)

        for (rawIndex, rawChar) in text.enumerated() {
            let folded = foldGlyph(rawChar)
            if folded.isWhitespace {
                if previousWasSpace { continue }
                normalized.append(" ")
                rawIndices.append(rawIndex)
                previousWasSpace = true
                continue
            }
            normalized.append(folded)
            rawIndices.append(rawIndex)
            previousWasSpace = false
        }

        // Trailing collapsed space (from trailing raw whitespace) is dropped.
        if normalized.hasSuffix(" ") {
            normalized.removeLast()
            rawIndices.removeLast()
        }
        return (normalized, rawIndices)
    }

    private static func foldGlyph(_ char: Character) -> Character {
        switch char {
        case "❯", "›", "»", "➜", "▸", "▶":
            return ">"
        case "'", "’", "‘", "´", "`":
            return "'"
        case "\u{201C}", "\u{201D}":
            return "\""
        case "—", "–":
            return "-"
        case "\u{00A0}":
            return " "
        default:
            return char
        }
    }
}
