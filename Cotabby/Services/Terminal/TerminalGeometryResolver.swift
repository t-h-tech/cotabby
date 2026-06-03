import AppKit
import ApplicationServices
import CoreGraphics
import Darwin.POSIX
import Foundation

/// File overview:
/// Estimates the screen position of the terminal cursor for ghost text overlay placement.
///
/// Terminals expose `AXWindow` and `AXFrame` through Accessibility even though their text content
/// is opaque. This resolver combines the terminal window frame with shell-reported row/column
/// positions to approximate where the cursor sits on screen.
///
/// The result is always `.estimated` quality — there is no AX-backed character-level geometry in
/// terminals. The overlay system treats `.estimated` conservatively, which is the right tradeoff:
/// a slightly imprecise overlay is better than no overlay at all.
enum TerminalGeometryResolver {

    /// Estimated metrics for one terminal character cell. Used to convert row/column to pixels.
    struct CellMetrics: Equatable, Sendable {
        /// Width of one character cell in points.
        let cellWidth: CGFloat
        /// Height of one character cell in points.
        let cellHeight: CGFloat
    }

    /// Default cell metrics when we cannot derive them from the terminal.
    /// Based on typical monospaced font rendering at 13pt (the macOS default for Terminal.app).
    static let defaultCellMetrics = CellMetrics(cellWidth: 7.8, cellHeight: 17.0)

    /// Resolves the terminal window frame via AX for the given process.
    ///
    /// Terminals expose `AXWindow` elements with `AXFrame` attributes even though their text
    /// content is not queryable. This gives us the window bounds for overlay containment.
    static func windowFrame(forPid pid: pid_t) -> CGRect? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)

        // Try the main/focused window first.
        if let frame = windowFrameFromAttribute(
            "AXMainWindow" as CFString,
            on: appElement
        ) {
            return frame
        }

        // Fall back to the first window in the window list.
        return windowFrameFromFirstWindow(on: appElement)
    }

    /// Estimates the cursor's screen position from the terminal window frame and shell-reported
    /// row/column.
    ///
    /// The coordinate system is Cocoa (bottom-left origin). The row/column values from the shell
    /// hook are 1-based. Row 1 is the top of the visible terminal area.
    static func estimatedCursorRect(
        windowFrame: CGRect,
        row: Int,
        column: Int,
        cellMetrics: CellMetrics = defaultCellMetrics
    ) -> CGRect {
        // Terminal content area typically has a small inset from the window frame.
        // These insets are approximate and terminal-dependent; close enough for overlay positioning.
        let contentInsetTop: CGFloat = 28  // Title bar height (approximate).
        let contentInsetLeft: CGFloat = 4
        let contentInsetBottom: CGFloat = 2

        // AX frame is in CG coordinates (top-left origin). Convert to Cocoa (bottom-left).
        // For the cursor position calculation, we work in CG space then convert.
        let zeroBasedRow = CGFloat(max(row - 1, 0))
        let zeroBasedCol = CGFloat(max(column - 1, 0))

        // In CG coordinates (top-left origin):
        let cursorCgX = windowFrame.minX + contentInsetLeft + zeroBasedCol * cellMetrics.cellWidth
        let cursorCgY = windowFrame.minY + contentInsetTop + zeroBasedRow * cellMetrics.cellHeight

        // The caret rect: a thin rectangle at the cursor position.
        return CGRect(
            x: cursorCgX,
            y: cursorCgY,
            width: cellMetrics.cellWidth,
            height: cellMetrics.cellHeight
        )
    }

    /// Produces a fallback caret rect when row/column are unavailable. Anchors to a conservative
    /// position near the bottom of the terminal window (where the prompt typically lives).
    static func fallbackCursorRect(windowFrame: CGRect) -> CGRect {
        let bottomInset: CGFloat = 40
        let leftInset: CGFloat = 20
        let cellHeight: CGFloat = defaultCellMetrics.cellHeight

        return CGRect(
            x: windowFrame.minX + leftInset,
            y: windowFrame.maxY - bottomInset,
            width: defaultCellMetrics.cellWidth,
            height: cellHeight
        )
    }

    /// Enriches a `TerminalFocusSnapshot` with window geometry and estimated cursor position.
    ///
    /// The `TerminalIntegrationService` calls this to add geometry data before publishing
    /// snapshots to the suggestion pipeline.
    static func enrichWithGeometry(_ snapshot: TerminalFocusSnapshot) -> TerminalFocusSnapshot {
        // Resolve the terminal's PID from the bundle identifier. We need the terminal app's PID,
        // not the shell's PID (which is a child process).
        let terminalPid = findTerminalPid(
            shellPid: snapshot.shellPid,
            terminalBundleIdentifier: snapshot.terminalBundleIdentifier
        )

        guard let terminalPid, let frame = windowFrame(forPid: terminalPid) else {
            return snapshot
        }

        let cursorRect: CGRect
        if let row = snapshot.cursorRow, let col = snapshot.cursorColumn {
            cursorRect = estimatedCursorRect(windowFrame: frame, row: row, column: col)
        } else {
            cursorRect = fallbackCursorRect(windowFrame: frame)
        }

        return TerminalFocusSnapshot(
            commandBuffer: snapshot.commandBuffer,
            cursorOffset: snapshot.cursorOffset,
            shellType: snapshot.shellType,
            terminalBundleIdentifier: snapshot.terminalBundleIdentifier,
            shellPid: snapshot.shellPid,
            terminalWindowFrame: frame,
            estimatedCursorPosition: CGPoint(x: cursorRect.midX, y: cursorRect.midY),
            cursorRow: snapshot.cursorRow,
            cursorColumn: snapshot.cursorColumn,
            timestamp: snapshot.timestamp
        )
    }

    /// Returns the terminal app's PID for the given bundle identifier.
    /// Used so the overlay system can find the terminal's window (not the shell's process).
    static func terminalAppPid(forBundleIdentifier bundleIdentifier: String) -> Int32? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first?.processIdentifier
    }

    // MARK: - Private

    private static func windowFrameFromAttribute(
        _ attribute: CFString,
        on appElement: AXUIElement
    ) -> CGRect? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, attribute, &value)
        guard result == .success, let windowElement = value else { return nil }

        let window = unsafeBitCast(windowElement, to: AXUIElement.self)
        return AXHelper.rectValue(for: "AXFrame" as CFString, on: window)
    }

    private static func windowFrameFromFirstWindow(on appElement: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            "AXWindows" as CFString,
            &value
        )
        guard result == .success,
              let windows = value as? [AXUIElement],
              let firstWindow = windows.first
        else {
            return nil
        }

        return AXHelper.rectValue(for: "AXFrame" as CFString, on: firstWindow)
    }

    /// Finds the terminal app's PID by looking up the parent of the shell process.
    ///
    /// The shell hook runs inside a child process of the terminal app. We need the terminal's
    /// PID to query its AX window frame. On macOS, `NSRunningApplication` with the bundle
    /// identifier is the most reliable lookup.
    private static func findTerminalPid(
        shellPid: Int32,
        terminalBundleIdentifier: String
    ) -> pid_t? {
        // Fast path: look up running apps by bundle identifier.
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: terminalBundleIdentifier
        )
        // If there's only one instance, use it. If multiple, pick the one that owns the shell.
        if apps.count == 1 {
            return apps.first?.processIdentifier
        }

        // Multiple terminal instances: walk the process tree to find the parent.
        // The shell's parent PID is typically the terminal app's PID.
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(shellPid, PROC_PIDTBSDINFO, 0, &info, infoSize)
        guard result == infoSize else {
            // If process info lookup fails, fall back to the first matching app.
            return apps.first?.processIdentifier
        }

        let parentPid = pid_t(info.pbi_ppid)
        if apps.contains(where: { $0.processIdentifier == parentPid }) {
            return parentPid
        }

        return apps.first?.processIdentifier
    }
}
