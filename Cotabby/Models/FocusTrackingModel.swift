import Combine
import Foundation

/// File overview:
/// Publishes focused-input snapshots to SwiftUI and other main-actor consumers. It keeps
/// Accessibility polling details hidden behind a small observable interface.
///
/// Bridges the polling-based focus tracker into SwiftUI-facing published state.
@MainActor
final class FocusTrackingModel: ObservableObject {
    @Published private(set) var snapshot: FocusSnapshot
    @Published private(set) var latestExternalApplication: FocusedApplicationIdentity?
    /// Debug-only polling diagnostics for the bottom-edge overlay; not used by suggestion generation.
    @Published private(set) var latestPollEvent: FocusPollingEvent?

    private let tracker: FocusTracker
    private let ignoredBundleIdentifier: String?
    private var isStarted = false

    /// When set, AX-polled snapshots for this bundle identifier are ignored so they don't
    /// overwrite terminal-injected snapshots. Cleared automatically when the user switches
    /// to a different app (the AX poll reports a different bundle ID).
    private var terminalInjectedBundleIdentifier: String?

    init(
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?,
        isCaptureSuppressedForBundle: @escaping @MainActor (String?) -> Bool = { _ in false },
        publishesPollingEvents: Bool = false
    ) {
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        tracker = FocusTracker(
            permissionProvider: permissionProvider,
            ignoredBundleIdentifier: ignoredBundleIdentifier,
            isCaptureSuppressedForBundle: isCaptureSuppressedForBundle
        )
        snapshot = tracker.snapshot
        latestExternalApplication = tracker.snapshot.externalApplicationIdentity(
            ignoredBundleIdentifier: ignoredBundleIdentifier
        )

        tracker.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            // When a terminal snapshot has been injected, AX polls for that same terminal
            // must not overwrite it — the terminal's AX tree has no editable text fields, so
            // the polled snapshot would always be .unsupported and would kill the suggestion.
            if let terminalBid = self.terminalInjectedBundleIdentifier {
                if snapshot.bundleIdentifier == terminalBid {
                    // Same terminal still focused — keep the terminal-injected snapshot.
                    return
                }
                // User switched away from the terminal — resume normal AX polling.
                self.terminalInjectedBundleIdentifier = nil
            }
            self.snapshot = snapshot
            self.updateLatestExternalApplication(from: snapshot)
        }

        if publishesPollingEvents {
            tracker.onPoll = { [weak self] event in
                self?.latestPollEvent = event
            }
        }
    }

    /// Starts focus observation once and treats later calls as a request for an immediate refresh.
    func start() {
        guard !isStarted else {
            tracker.refreshNow()
            return
        }

        isStarted = true
        tracker.start()
    }

    /// Stops observation while leaving the last captured snapshot available for UI consumers.
    func stop() {
        isStarted = false
        tracker.stop()
    }

    /// A manual refresh is useful when another subsystem already knows "input just changed" and
    /// wants the latest AX snapshot immediately instead of waiting for the next timer tick.
    func refreshNow() {
        tracker.refreshNow()
    }

    /// Updates the AX polling interval at runtime. Restarts the timer if already running.
    func updatePollInterval(milliseconds: Int) {
        tracker.updatePollInterval(TimeInterval(milliseconds) / 1000.0)
    }

    /// Injects a terminal-sourced focus snapshot, bypassing AX polling.
    ///
    /// When a shell integration session is active, the terminal subsystem converts its IPC data into
    /// a `FocusSnapshot` and pushes it here. The published snapshot triggers the same Combine
    /// pipeline that AX-polled snapshots use, so the coordinator sees terminal input identically.
    func injectTerminalSnapshot(_ terminalSnapshot: FocusSnapshot) {
        terminalInjectedBundleIdentifier = terminalSnapshot.bundleIdentifier
        snapshot = terminalSnapshot
        updateLatestExternalApplication(from: terminalSnapshot)
    }

    /// Clears the terminal injection suppression so AX polling resumes for all apps.
    /// Called when a terminal shell integration session disconnects.
    func clearTerminalInjection() {
        terminalInjectedBundleIdentifier = nil
    }

    /// The menu bar needs a compact status string, not the full diagnostic reason.
    var menuBarStatusText: String {
        snapshot.capability.shortLabel
    }

    var menuBarSymbolName: String {
        switch snapshot.capability {
        case .supported:
            return "checkmark.circle"
        case .blocked:
            return "hand.raised.circle"
        case .unsupported:
            return "xmark.circle"
        }
    }

    private func updateLatestExternalApplication(from snapshot: FocusSnapshot) {
        guard let application = snapshot.externalApplicationIdentity(
            ignoredBundleIdentifier: ignoredBundleIdentifier
        ) else {
            return
        }

        latestExternalApplication = application
    }
}

extension FocusTrackingModel: SuggestionFocusProviding {
    /// Exposing an erased publisher keeps `SuggestionCoordinator` coupled to "a stream of focus
    /// snapshots" rather than the implementation detail that this model uses `@Published`.
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        $snapshot.eraseToAnyPublisher()
    }
}
