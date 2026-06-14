import Combine
import Foundation
import XCTest
@testable import Cotabby

/// Tests the coordinator-level acceptance contract.
///
/// `InputMonitor` owns the physical key event, but `SuggestionCoordinator` remains the final
/// validator for whether visible ghost text can be committed. These tests keep that boundary
/// explicit so future state-machine edits do not accidentally reintroduce `.ready` as a hard gate.
final class SuggestionCoordinatorAcceptanceTests: XCTestCase {
    private static var retainedCoordinators: [SuggestionCoordinator] = []

    override func tearDown() {
        runOnMainActor {
            Self.retainedCoordinators.removeAll()
        }
        super.tearDown()
    }

    func test_acceptCurrentSuggestionAllowsVisibleSessionWhileDebugStateIsDebouncing() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " world again",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )
            coordinator.state = .debouncing

            XCTAssertTrue(
                inputMonitor.shouldConsumeAcceptKeyProvider(),
                "Preflight should depend on visible overlay, not `.ready`."
            )
            XCTAssertTrue(coordinator.acceptCurrentSuggestion())

            XCTAssertEqual(inserter.insertedChunks, [" world"])
            XCTAssertEqual(coordinator.latestAcceptanceAction, "Accepted next chunk with Tab.")
            guard case let .ready(remainingText, _) = coordinator.state else {
                XCTFail("Partial acceptance should leave the remaining suggestion ready.")
                return
            }
            XCTAssertEqual(remainingText, " again")
        }
    }

    func test_acceptCurrentSuggestionCleansVisibleOverlayWhenSessionDisappears() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let overlayState = OverlayState.visible(
                text: " stale",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: SuggestionInteractionState()
            )
            coordinator.state = .debouncing

            XCTAssertTrue(
                inputMonitor.shouldConsumeAcceptKeyProvider(),
                "A visible stale overlay should still route the accept key into the coordinator for cleanup."
            )
            XCTAssertFalse(coordinator.acceptCurrentSuggestion())

            XCTAssertTrue(inserter.insertedChunks.isEmpty)
            XCTAssertFalse(coordinator.overlayState.isVisible)
            XCTAssertEqual(coordinator.state, .idle)
        }
    }

    func test_acceptingFinalChunkDefersRegenerationAndRecordsAcceptedTail() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "what's on your mind")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " today",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )

            XCTAssertTrue(coordinator.acceptCurrentSuggestion())

            XCTAssertEqual(inserter.insertedChunks, [" today"])
            // The final-chunk accept must not immediately re-enter debouncing. It waits for the host
            // to publish the insert, so synchronously the coordinator is idle with the overlay hidden.
            XCTAssertEqual(coordinator.state, .idle)
            XCTAssertFalse(coordinator.overlayState.isVisible)
            // It records what it committed so `apply` can drop a stale echo of the same tail.
            XCTAssertEqual(
                coordinator.lastAcceptedTail,
                AcceptedSuggestionTail(text: " today", precedingText: "what's on your mind")
            )
        }
    }

    func test_rapidSecondAcceptDuringRegenerationIsConsumedNotPassedThrough() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "what's on your mind")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            _ = interactionState.startSession(
                fullText: " today",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: " today",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )

            // First Tab accepts the only remaining chunk, exhausts the session, and arms the window.
            XCTAssertTrue(coordinator.acceptCurrentSuggestion())
            XCTAssertEqual(inserter.insertedChunks, [" today"])
            XCTAssertTrue(coordinator.isPostExhaustionAcceptanceArmed)
            XCTAssertFalse(coordinator.overlayState.isVisible)
            // Ownership of Tab was re-asserted even though the overlay is now hidden.
            XCTAssertEqual(inputMonitor.acceptInterceptionRequests.last, true)
            XCTAssertTrue(
                inputMonitor.shouldConsumeAcceptKeyProvider(),
                "The accept tap must keep owning Tab while the continuation regenerates."
            )

            // The rapid second Tab lands before the continuation regenerates. It must be swallowed
            // (consumed) and queued — never forwarded to the host as a real Tab that moves focus.
            XCTAssertTrue(
                coordinator.acceptCurrentSuggestion(),
                "A fast follow-up Tab during regeneration must be consumed, not passed through to the host."
            )
            XCTAssertEqual(
                inserter.insertedChunks,
                [" today"],
                "The second Tab has nothing to insert yet; it is queued, not inserted."
            )
            XCTAssertTrue(coordinator.hasQueuedPostExhaustionAccept)
        }
    }

    func test_postExhaustionWindowReleasesAcceptKeyWhenOverlayHides() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "what's on your mind")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            _ = interactionState.startSession(
                fullText: " today",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: " today",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )

            XCTAssertTrue(coordinator.acceptCurrentSuggestion())
            XCTAssertTrue(coordinator.isPostExhaustionAcceptanceArmed)

            // Any teardown that hides the overlay (focus change, typing, dismissal, an empty
            // regeneration) must end the window so the user can Tab out of the field normally again.
            coordinator.invalidateActiveSuggestion(reason: "Focus moved to another field.")

            XCTAssertFalse(coordinator.isPostExhaustionAcceptanceArmed)
            XCTAssertFalse(coordinator.hasQueuedPostExhaustionAccept)
            XCTAssertFalse(
                inputMonitor.shouldConsumeAcceptKeyProvider(),
                "Once the window is released the accept tap should stop owning Tab."
            )
            XCTAssertFalse(
                coordinator.acceptCurrentSuggestion(),
                "With the window released and no suggestion, Tab must pass through to the host."
            )
        }
    }

    func test_queuedPostExhaustionAcceptInsertsNextWordWhenContinuationArrives() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " world again",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )
            // Simulate a Tab that was swallowed and queued while this continuation was still loading;
            // `apply` calls `flushQueuedPostExhaustionAcceptIfNeeded` once the suggestion is on screen.
            coordinator.isPostExhaustionAcceptanceArmed = true
            coordinator.hasQueuedPostExhaustionAccept = true

            coordinator.flushQueuedPostExhaustionAcceptIfNeeded()

            XCTAssertEqual(
                inserter.insertedChunks,
                [" world"],
                "The queued Tab should accept the continuation's first word."
            )
            XCTAssertFalse(coordinator.isPostExhaustionAcceptanceArmed)
            XCTAssertFalse(coordinator.hasQueuedPostExhaustionAccept)
        }
    }

    // MARK: - Terminal-mode acceptance (Phase 1 regression coverage)

    /// Regression test for the B.3 rollout bug — Cotabby used to short-circuit the inserter call
    /// when the frontmost app was a terminal with shell integration, expecting the shell hook's
    /// `_cotabby_forward_char` widget to insert via `terminal-suggestion.txt`. B.3 deleted that
    /// file-based path, so the short-circuit meant Right Arrow ate the keystroke but pasted
    /// nothing. This test pins the new contract: terminal acceptance MUST route through
    /// `SuggestionInserter.insert(...)`, where the production inserter's `isTerminalMode` flag
    /// flips it into the bracketed-paste Cmd+V path. Stub inserter records the call so the test
    /// proves the coordinator made it.
    func test_acceptanceInGhosttyTerminal_routesToInserter() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: "com.mitchellh.ghostty",
                precedingText: "git "
            )
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: "checkout main",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )
            // Simulate the live terminal-integration session that previously gated the skip.
            coordinator.terminalIntegrationActiveProvider = { true }

            XCTAssertTrue(coordinator.acceptCurrentSuggestion())

            XCTAssertFalse(
                inserter.insertedChunks.isEmpty,
                "Acceptance in a terminal must call SuggestionInserter.insert(...). "
                    + "If this fails, the B.3 regression has come back — Cotabby is eating the "
                    + "accept keystroke without pasting."
            )
            XCTAssertEqual(
                inserter.insertedChunks,
                ["checkout"],
                "Terminal acceptance should insert the next word chunk, same as non-terminal apps."
            )
        }
    }

    /// Parity check: with `terminalIntegrationActiveProvider == false` the inserter still fires
    /// (the unrelated non-terminal path is untouched). This catches a hypothetical regression
    /// where someone "fixes" terminal-mode by inverting the gate and accidentally breaks the
    /// non-terminal acceptance flow.
    func test_acceptanceOutsideTerminal_stillRoutesToInserter() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: " world",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )
            coordinator.terminalIntegrationActiveProvider = { false }

            XCTAssertTrue(coordinator.acceptCurrentSuggestion())
            XCTAssertEqual(inserter.insertedChunks, [" world"])
        }
    }

    /// Insertion failure path: a terminal-mode insert that returns false (e.g. clipboard
    /// permission denied) must still clear the overlay and surface the error. Mirrors the
    /// non-terminal failure handling so the user sees the same UX regardless of terminal mode.
    func test_terminalAcceptanceWithFailedInsert_clearsOverlay() {
        runOnMainActor {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: "com.mitchellh.ghostty",
                precedingText: "git "
            )
            let context = FocusedInputContext(snapshot: snapshot, generation: 7)
            let interactionState = SuggestionInteractionState()
            let session = interactionState.startSession(
                fullText: "checkout",
                liveContext: context,
                latency: 0.1
            )
            let overlayState = OverlayState.visible(
                text: session.remainingText,
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                mode: .inline
            )
            let inputMonitor = StubSuggestionInputMonitor()
            let inserter = StubSuggestionInserter()
            inserter.shouldInsert = false
            inserter.lastErrorMessage = "Clipboard write denied"
            let coordinator = makeCoordinator(
                snapshot: snapshot,
                overlayState: overlayState,
                inputMonitor: inputMonitor,
                inserter: inserter,
                interactionState: interactionState
            )
            coordinator.terminalIntegrationActiveProvider = { true }

            XCTAssertFalse(coordinator.acceptCurrentSuggestion())
            XCTAssertEqual(
                inserter.insertedChunks,
                ["checkout"],
                "The insert call still has to happen so the coordinator knows it failed."
            )
            XCTAssertFalse(coordinator.overlayState.isVisible)
            XCTAssertEqual(coordinator.state, .idle)
        }
    }

    @MainActor
    private func makeCoordinator(
        snapshot: FocusedInputSnapshot,
        overlayState: OverlayState,
        inputMonitor: StubSuggestionInputMonitor,
        inserter: StubSuggestionInserter,
        interactionState: SuggestionInteractionState
    ) -> SuggestionCoordinator {
        let focusSnapshot = FocusSnapshot(
            applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier,
            capability: .supported,
            context: snapshot,
            inspection: nil
        )
        let coordinator = SuggestionCoordinator(
            permissionManager: StubSuggestionPermissionProvider(),
            focusModel: StubSuggestionFocusProvider(snapshot: focusSnapshot),
            inputMonitor: inputMonitor,
            overlayController: StubSuggestionOverlayController(state: overlayState),
            suggestionInserter: inserter,
            suggestionEngine: StubSuggestionEngine(),
            suggestionSettings: StubSuggestionSettingsProvider(),
            clipboardContextProvider: StubClipboardContextProvider(),
            clipboardRelevanceFilter: StubClipboardRelevanceFilter(),
            visualContextCoordinator: StubVisualContextCoordinator(),
            interactionState: interactionState,
            workController: SuggestionWorkController(),
            configuration: .standard,
            userDefaults: UserDefaults(suiteName: "CotabbyTests.\(UUID().uuidString)") ?? .standard
        )
        Self.retainedCoordinators.append(coordinator)
        return coordinator
    }
}

@MainActor
private final class StubSuggestionPermissionProvider: SuggestionPermissionProviding {
    var inputMonitoringGranted = true
    var screenRecordingGranted = true

    private let inputSubject = PassthroughSubject<Bool, Never>()
    private let screenSubject = PassthroughSubject<Bool, Never>()

    var inputMonitoringGrantedPublisher: AnyPublisher<Bool, Never> {
        inputSubject.eraseToAnyPublisher()
    }

    var screenRecordingGrantedPublisher: AnyPublisher<Bool, Never> {
        screenSubject.eraseToAnyPublisher()
    }
}

@MainActor
private final class StubSuggestionFocusProvider: SuggestionFocusProviding {
    var snapshot: FocusSnapshot

    private let snapshotSubject = PassthroughSubject<FocusSnapshot, Never>()

    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    init(snapshot: FocusSnapshot) {
        self.snapshot = snapshot
    }

    func refreshNow() {}
}

@MainActor
private final class StubSuggestionInputMonitor: SuggestionInputMonitoring {
    var onEvent: ((CapturedInputEvent) -> Bool)?
    var onSuppressedSyntheticInput: (() -> Void)?
    var shouldConsumeAcceptKeyProvider: @MainActor @Sendable () -> Bool = { false }
    private(set) var acceptInterceptionRequests: [Bool] = []

    func setAcceptInterceptionActive(_ active: Bool) {
        acceptInterceptionRequests.append(active)
    }
}

@MainActor
private final class StubSuggestionOverlayController: SuggestionOverlayControlling {
    var state: OverlayState
    var onStateChange: ((OverlayState) -> Void)?

    init(state: OverlayState) {
        self.state = state
    }

    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry) {
        state = .visible(text: text, geometry: geometry, mode: .inline)
        onStateChange?(state)
    }

    func hide(reason: String) {
        state = .hidden(reason: reason)
        onStateChange?(state)
    }

    func setCurrentBundleIdentifier(_ bundleIdentifier: String?) {
        currentBundleIdentifier = bundleIdentifier
    }

    private(set) var currentBundleIdentifier: String?
}

@MainActor
private final class StubSuggestionInserter: SuggestionInserting {
    var lastErrorMessage: String?
    var insertedChunks: [String] = []
    var shouldInsert = true

    func insert(_ suggestion: String) -> Bool {
        insertedChunks.append(suggestion)
        return shouldInsert
    }
}

private enum StubSuggestionEngineError: Error {
    case unexpectedGeneration
}

@MainActor
private final class StubSuggestionEngine: SuggestionGenerating {
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        throw StubSuggestionEngineError.unexpectedGeneration
    }

    func resetCachedGenerationContext() async {}
}

@MainActor
private final class StubSuggestionSettingsProvider: SuggestionSettingsProviding {
    var snapshot = CotabbyTestFixtures.settingsSnapshot()

    private let snapshotSubject = PassthroughSubject<SuggestionSettingsSnapshot, Never>()

    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }
}

@MainActor
private final class StubClipboardContextProvider: ClipboardContextProviding {
    var currentChangeCount = 0

    func currentContext() -> String? {
        nil
    }
}

@MainActor
private final class StubClipboardRelevanceFilter: ClipboardRelevanceFiltering {
    func filter(
        clipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String? {
        nil
    }
}

@MainActor
private final class StubVisualContextCoordinator: VisualContextCoordinating {
    var status: VisualContextStatus = .idle
    var latestExcerpt: String?
    var onStateChange: ((VisualContextStatus, String?) -> Void)?
    var onInjectedContextReady: ((FocusedInputIdentity) -> Void)?

    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot) {}

    func cancel(resetState: Bool) {}

    func excerpt(for context: FocusedInputContext) -> String? {
        nil
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
