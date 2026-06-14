import AppKit
import CoreGraphics
import Foundation
import Logging
import ScreenCaptureKit

/// File overview:
/// Small ScreenCaptureKit wrapper sized for the Claude Code TUI path. It does two jobs:
///   1. Discover the frontmost on-screen window for a given terminal PID, returning its
///      screen-space frame in CG (top-left origin) coordinates.
///   2. Capture a screen-space CGRect region from that window as a downsampled CGImage.
///
/// This is intentionally narrower than `WindowScreenshotService`, which takes a
/// `FocusedInputSnapshot` and computes its own crop. The TUI coordinator already knows the
/// crop rect (bottom band of the terminal window), so duplicating the per-input-field
/// arithmetic would only add coupling. Both services share `SCShareableContent` lookups via
/// the same callback pattern.
@MainActor
final class TuiScreenshotService {

    enum TuiScreenshotError: LocalizedError {
        case permissionDenied
        case noWindowForProcess(pid_t)
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission is required for Claude Code TUI autocomplete."
            case let .noWindowForProcess(pid):
                return "No on-screen window for terminal process \(pid)."
            case let .captureFailed(message):
                return "Claude Code TUI screenshot failed: \(message)"
            }
        }
    }

    /// Returns the terminal window's screen-space frame (CG coordinates, top-left origin).
    /// Nil when no on-screen window matches — the caller should treat this as "Claude Code is
    /// minimized / hidden / on another Space" and back off.
    func windowFrame(forPid pid: Int32) async throws -> CGRect? {
        guard CGPreflightScreenCaptureAccess() else {
            throw TuiScreenshotError.permissionDenied
        }
        let content = try await shareableContent()
        let window = content.windows.first { window in
            guard let owningPid = window.owningApplication?.processID else { return false }
            return owningPid == pid_t(pid) && window.isOnScreen && window.isActive
        } ?? content.windows.first { window in
            guard let owningPid = window.owningApplication?.processID else { return false }
            return owningPid == pid_t(pid) && window.isOnScreen
        }
        return window?.frame
    }

    /// Capture `region` (screen-space CG rect) from the terminal window owned by `pid`. The
    /// returned image is downsampled by the screen's backing scale so OCR runs on roughly the
    /// physical pixel resolution rather than a 2x retina blowup.
    func captureRegion(forPid pid: Int32, region: CGRect) async throws -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            throw TuiScreenshotError.permissionDenied
        }
        let content = try await shareableContent()
        // Same selection order as `windowFrame(forPid:)` — active window first. These are two
        // separate SCShareableContent fetches; preferring different windows here translates
        // the region into the WRONG window's local space whenever the app has more than one
        // window (the standard claude-in-window-A, prompt-in-window-B layout).
        let selectedWindow = content.windows.first { window in
            guard let owningPid = window.owningApplication?.processID else { return false }
            return owningPid == pid_t(pid) && window.isOnScreen && window.isActive
        } ?? content.windows.first { window in
            guard let owningPid = window.owningApplication?.processID else { return false }
            return owningPid == pid_t(pid) && window.isOnScreen
        }
        guard let window = selectedWindow else {
            throw TuiScreenshotError.noWindowForProcess(pid_t(pid))
        }

        // Clamp the requested region to the window's frame. ScreenCaptureKit's `sourceRect` is
        // window-local, so we translate from screen-space to local before clamping.
        let localRect = CGRect(
            x: region.minX - window.frame.minX,
            y: region.minY - window.frame.minY,
            width: region.width,
            height: region.height
        ).intersection(CGRect(origin: .zero, size: window.frame.size))
        guard !localRect.isEmpty else { return nil }

        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = max(Int((localRect.width * backingScale).rounded(.up)), 1)
        configuration.height = max(Int((localRect.height * backingScale).rounded(.up)), 1)
        configuration.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await captureImage(filter: filter, configuration: configuration)
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: TuiScreenshotError.captureFailed(error.localizedDescription))
                    return
                }
                guard let content else {
                    continuation.resume(throwing: TuiScreenshotError.captureFailed("Shareable content unavailable."))
                    return
                }
                continuation.resume(returning: content)
            }
        }
    }

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: TuiScreenshotError.captureFailed(error.localizedDescription))
                    return
                }
                guard let image else {
                    continuation.resume(throwing: TuiScreenshotError.captureFailed("Capture returned no image."))
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }
}
