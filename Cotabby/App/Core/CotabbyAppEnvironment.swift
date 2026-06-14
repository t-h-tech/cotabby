import AppKit
import Combine
import Foundation
import Logging

/// File overview:
/// Builds Cotabby's long-lived dependency graph in one place. This is the app's composition model:
/// services are constructed once here, then handed to `AppDelegate` and the UI as shared owners.
///
/// In frontend terms, this plays the role of a top-level dependency container or provider tree.
/// The important architectural idea is that creation happens in one place, while usage happens
/// elsewhere. That keeps lifecycle ownership easy to follow.
@MainActor
final class CotabbyAppEnvironment {
    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let modelDownloadManager: ModelDownloadManager
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    let appUpdateManager: AppUpdateManager
    let launchAtLoginService: LaunchAtLoginService
    let permissionGuidanceController: PermissionGuidanceController
    let suggestionSettings: SuggestionSettingsModel
    let foundationModelAvailabilityService: FoundationModelAvailabilityService
    let clipboardContextProvider: ClipboardContextProvider
    let suggestionCoordinator: SuggestionCoordinator
    /// Shared with the Advanced settings pane so the user can fire an ad-hoc generation against
    /// the currently-selected engine and verify that Extended Context (and other prompt inputs)
    /// are actually shaping the output. Reusing the live router means the playground produces the
    /// same answer the autocomplete pipeline would, not a stand-in.
    let suggestionEngine: any SuggestionGenerating
    let emojiPickerController: EmojiPickerController
    let emojiUsageStore: EmojiUsageStore
    let welcomeCoordinator: WelcomeCoordinator
    let huggingFaceSearchService: HuggingFaceSearchService
    let performanceMetricsStore: PerformanceMetricsStore
    let settingsCoordinator: SettingsCoordinator
    let activationIndicatorController: ActivationIndicatorController
    let focusDebugOverlayController: FocusDebugOverlayController?
    let terminalIntegrationService: TerminalIntegrationService
    let tuiScreenshotService: TuiScreenshotService
    let tuiContextCoordinator: TuiContextCoordinator
    let shellPromptGeometryCoordinator: ShellPromptGeometryCoordinator

    private var cancellables = Set<AnyCancellable>()

    init() {
        CotabbyLogger.app.info("Building dependency graph")
        let configuration = SuggestionConfiguration.standard
        let permissionManager = PermissionManager()
        let permissionGuidanceController = PermissionGuidanceController(
            permissionManager: permissionManager
        )
        let runtimeManager = LlamaRuntimeManager()
        let runtimeModel = RuntimeBootstrapModel(runtimeManager: runtimeManager)
        let modelDownloadManager = ModelDownloadManager()
        let suggestionSettings = SuggestionSettingsModel(configuration: configuration)
        let foundationModelAvailabilityService = FoundationModelAvailabilityService()
        let suppressionController = InputSuppressionController()
        let inputMonitor = InputMonitor(
            permissionProvider: { permissionManager.inputMonitoringGranted },
            suppressionController: suppressionController
        )
        // Acceptance key providers are set after focusModel and terminalIntegrationService
        // are created, since terminal-aware key selection reads both.
        // `fullAcceptance*` providers are set later, alongside the terminal-aware acceptance
        // closures, so the per-app resolver can read the frontmost bundle id from focusModel.
        inputMonitor.globalToggleKeyCodeProvider = { suggestionSettings.globalToggleKeyCode }
        inputMonitor.globalToggleKeyModifiersProvider = { suggestionSettings.globalToggleKeyModifiers }
        inputMonitor.onGlobalToggleHotkey = { [weak suggestionSettings] in
            suggestionSettings?.toggleGloballyEnabled()
        }
        // Stop the deep AX walk when Cotabby is disabled for the focused app. Without this the
        // focus poll keeps enumerating the frontmost app's AX attributes every 50-80ms even after
        // the user toggles Cotabby off, which can dismiss transient popovers in apps like Calendar
        // (#476). Gating here also makes the "I disabled it but the bug remained" symptom go away:
        // the disable toggles now actually stop touching the focused app.
        let terminalIntegrationService = TerminalIntegrationService()
        let focusModel = FocusTrackingModel(
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier,
            isCaptureSuppressedForBundle: { bundleIdentifier in
                Self.isCaptureSuppressed(bundleIdentifier: bundleIdentifier, settings: suggestionSettings)
            },
            publishesPollingEvents: FocusDebugOverlayController.isEnabled
        )
        // The snapshot is poll-based, so after a fast app switch the closure may briefly
        // evaluate against the previous app's identity until the next AX poll fires. This
        // is the same race the downstream evaluator already has — not a new regression.

        inputMonitor.shouldProcessEventsProvider = { [weak focusModel] in
            Self.shouldProcessEvents(
                snapshot: focusModel?.snapshot,
                settings: suggestionSettings,
                terminalIntegrationService: terminalIntegrationService
            )
        }
        // Single source of truth for "the user is typing into a shell": dedicated terminals
        // always; embedded-terminal hosts (VS Code, Cursor…) only while one of their shells
        // holds a live integration session. Drives the accept-key resolution below, the
        // overlay's render-mode/hint decisions, and nothing else — keep it that way so every
        // shell-facing behavior flips together.
        let shellSurfaceProvider: (String?) -> Bool = { bundleIdentifier in
            Self.isShellSurface(
                bundleIdentifier: bundleIdentifier,
                terminalIntegrationService: terminalIntegrationService
            )
        }

        // Now that focusModel and terminalIntegrationService exist, set the terminal-aware
        // acceptance key providers. Resolution runs at event time so a fast app switch never
        // resolves against stale state. Precedence (highest first):
        //   1. terminal-specific binding (any shell surface — see `shellSurfaceProvider`),
        //   2. per-app override for the frontmost app (`ShortcutResolver`),
        //   3. global accept binding.
        // Same shape applies to the full-accept providers below.
        inputMonitor.acceptanceKeyCodeProvider = { [weak focusModel] in
            let bid = focusModel?.snapshot.bundleIdentifier
            return Self.terminalAwareAcceptanceKeyCode(
                bundleIdentifier: bid,
                isShellSurface: shellSurfaceProvider(bid),
                settings: suggestionSettings
            )
        }
        inputMonitor.acceptanceKeyModifiersProvider = { [weak focusModel] in
            let bid = focusModel?.snapshot.bundleIdentifier
            return Self.terminalAwareAcceptanceKeyModifiers(
                bundleIdentifier: bid,
                isShellSurface: shellSurfaceProvider(bid),
                settings: suggestionSettings
            )
        }
        inputMonitor.fullAcceptanceKeyCodeProvider = { [weak focusModel] in
            ShortcutResolver.fullAcceptBinding(
                frontmostBundleIdentifier: focusModel?.snapshot.bundleIdentifier,
                overrides: suggestionSettings.perAppShortcutOverrides,
                globalKeyCode: suggestionSettings.fullAcceptanceKeyCode,
                globalModifiers: suggestionSettings.fullAcceptanceKeyModifiers,
                globalLabel: suggestionSettings.fullAcceptanceKeyLabel
            ).keyCode
        }
        inputMonitor.fullAcceptanceKeyModifiersProvider = { [weak focusModel] in
            ShortcutResolver.fullAcceptBinding(
                frontmostBundleIdentifier: focusModel?.snapshot.bundleIdentifier,
                overrides: suggestionSettings.perAppShortcutOverrides,
                globalKeyCode: suggestionSettings.fullAcceptanceKeyCode,
                globalModifiers: suggestionSettings.fullAcceptanceKeyModifiers,
                globalLabel: suggestionSettings.fullAcceptanceKeyLabel
            ).modifiers
        }
        // Terminal acceptance now flows through Cotabby's own clipboard-paste path
        // (`SuggestionInserter.isTerminalMode == true`, which uses bracketed paste / Cmd+V).
        // Cotabby consumes the keystroke just like in any other app, so the shell hook does NOT
        // also insert via its file-based `_cotabby_forward_char` widget — that path is left in
        // the scripts as a documented fallback for terminals where CGEvent-based paste is
        // unreliable, and it naturally no-ops because `terminal-suggestion.txt` is no longer
        // written. Keeping pass-through default to false unifies all surfaces on a single
        // acceptance path, removes the per-keystroke file race the old path created, and means
        // the configured terminal accept key actually does what it says.
        inputMonitor.shouldPassThroughAcceptKeyProvider = { false }
        let appUpdateManager = AppUpdateManager()
        let launchAtLoginService = LaunchAtLoginService()
        let welcomeCoordinator = WelcomeCoordinator(
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService
        )
        let huggingFaceSearchService = HuggingFaceSearchService()
        let performanceMetricsStore = PerformanceMetricsStore()
        // Settings coordinator construction is deferred below until after `suggestionEngine` is
        // built — the Advanced pane's "try it" playground needs the engine so it can fire ad-hoc
        // generations using the same router the autocomplete pipeline does.
        let suggestionInserter = SuggestionInserter(suppressionController: suppressionController)
        let overlayController = OverlayController(suggestionSettings: suggestionSettings)
        // Shell surfaces render inline ghost text and advertise the terminal accept key —
        // same rule the InputMonitor providers use, so UI and key handling never disagree.
        overlayController.shellSurfaceProvider = shellSurfaceProvider
        let activationIndicatorController = ActivationIndicatorController()
        let clipboardContextProvider = ClipboardContextProvider()
        let clipboardRelevanceFilter = ClipboardRelevanceFilter()
        let screenshotContextGenerator = ScreenshotContextGenerator()
        let visualContextCoordinator = VisualContextCoordinator(
            screenshotContextGenerator: screenshotContextGenerator,
            screenRecordingPermissionProvider: { permissionManager.screenRecordingGranted }
        )
        let foundationModelEngine: any SuggestionGenerating
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            foundationModelEngine = FoundationModelSuggestionEngine(
                availabilityService: foundationModelAvailabilityService
            )
            CotabbyLogger.app.info("Foundation model engine available")
        } else {
            foundationModelEngine = UnavailableSuggestionEngine(
                message: foundationModelAvailabilityService.userVisibleMessage
            )
            CotabbyLogger.app.info("Foundation model engine unavailable (macOS version)")
        }
        #else
        foundationModelEngine = UnavailableSuggestionEngine(
            message: foundationModelAvailabilityService.userVisibleMessage
        )
        CotabbyLogger.app.info("Foundation model engine unavailable (SDK)")
        #endif

        let suggestionEngine: any SuggestionGenerating = SuggestionEngineRouter(
            suggestionSettings: suggestionSettings,
            foundationModelEngine: foundationModelEngine,
            llamaEngine: LlamaSuggestionEngine(runtimeManager: runtimeManager),
            performanceMetricsStore: performanceMetricsStore,
            llamaModelNameProvider: { [weak runtimeManager] in
                runtimeManager?.currentModelFilename
            }
        )

        // Per-user emoji recents/frequency. Built before the settings coordinator so the
        // "Clear History" control can reach it, and before the picker which reads and writes it.
        let emojiUsageStore = EmojiUsageStore()

        let settingsCoordinator = SettingsCoordinator(
            appUpdateManager: appUpdateManager,
            launchAtLoginService: launchAtLoginService,
            permissionManager: permissionManager,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            huggingFaceSearchService: huggingFaceSearchService,
            suggestionEngine: suggestionEngine,
            configuration: configuration,
            performanceMetricsStore: performanceMetricsStore,
            onShowWelcome: { [weak welcomeCoordinator] in
                welcomeCoordinator?.showWelcome()
            },
            clearEmojiHistory: { emojiUsageStore.clear() }
        )

        let interactionState = SuggestionInteractionState()
        let workController = SuggestionWorkController()
        let suggestionCoordinator = SuggestionCoordinator(
            permissionManager: permissionManager,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            suggestionInserter: suggestionInserter,
            suggestionEngine: suggestionEngine,
            suggestionSettings: suggestionSettings,
            clipboardContextProvider: clipboardContextProvider,
            clipboardRelevanceFilter: clipboardRelevanceFilter,
            visualContextCoordinator: visualContextCoordinator,
            interactionState: interactionState,
            workController: workController,
            configuration: configuration
        )

        // The emoji picker is a sibling to the suggestion coordinator. It reuses the input monitor,
        // focus model, and inserter, but owns its own trigger state machine and floating panel.
        let emojiPickerController = EmojiPickerController(
            matcher: EmojiMatcher(catalog: EmojiCatalog.bundled()),
            panel: EmojiPickerPanelController(),
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            inserter: suggestionInserter,
            isEnabled: { suggestionSettings.isEmojiPickerEnabled },
            emojiPreferences: { suggestionSettings.emojiVariantPreferences },
            acceptKeyLabel: { suggestionSettings.emojiPickerAcceptKeyLabel },
            emojiUsage: { emojiUsageStore.snapshot() },
            recordEmojiUsage: { emojiUsageStore.record(alias: $0) }
        )
        // Give the picker first look at every keystroke the coordinator receives, so it can detect the
        // `:` trigger and drive its state machine without changing who owns `inputMonitor.onEvent`.
        suggestionCoordinator.emojiInputObserver = { [weak emojiPickerController] event in
            Self.observeEmoji(event: event, controller: emojiPickerController)
        }

        // Terminal integration: tell the coordinator that *any* terminal-source is live for the
        // frontmost app. The flag is a single boolean for the evaluator, but the closure ORs the
        // two sources defined in Sub-plan D so adding the TUI path doesn't fork the gating
        // logic. Precedence (TUI over shell) is captured by the `FocusSnapshot.context.role`
        // string, which the adapters set distinctly.
        suggestionCoordinator.terminalIntegrationActiveProvider = { [weak focusModel] in
            Self.isTerminalIntegrationActive(
                snapshot: focusModel?.snapshot,
                settings: suggestionSettings,
                terminalIntegrationService: terminalIntegrationService
            )
        }

        // OCR prompt anchors for shell-surface ghost positioning. The screenshot service is
        // shared with the Claude Code TUI pipeline below; constructed here because the shell
        // report handler needs the geometry coordinator.
        let tuiScreenshotService = TuiScreenshotService()
        let shellPromptGeometryCoordinator = ShellPromptGeometryCoordinator(
            captureSession: { snapshot in
                try await Self.shellCaptureSession(snapshot: snapshot, screenshotService: tuiScreenshotService)
            },
            windowFrameProvider: { snapshot in
                Self.shellWindowFrame(snapshot: snapshot)
            },
            isEnabled: { [weak permissionManager] in
                Self.screenRecordingGranted(permissionManager: permissionManager)
            }
        )

        // When a shell hook reports buffer state, enrich it with geometry and inject it into
        // the focus model so the suggestion pipeline sees terminal input like any other field.
        // Shared by the live report path AND the anchor-resolved re-injection below.
        terminalIntegrationService.onSnapshotUpdate = { [weak focusModel] rawSnapshot in
            Self.handleShellReport(
                rawSnapshot,
                focusModel: focusModel,
                suggestionInserter: suggestionInserter,
                geometryCoordinator: shellPromptGeometryCoordinator
            )
        }
        // A fresh anchor re-runs the report path with the shell's LATEST buffer so the ghost
        // snaps from hidden to positioned without waiting for the next keystroke.
        shellPromptGeometryCoordinator.onAnchorResolved = { [weak focusModel] shellPid in
            Self.reinjectLatestSnapshot(
                shellPid: shellPid,
                focusModel: focusModel,
                suggestionInserter: suggestionInserter,
                geometryCoordinator: shellPromptGeometryCoordinator,
                terminalIntegrationService: terminalIntegrationService
            )
        }
        // Optimistic local echo after Cotabby's own terminal paste — bracketed paste never
        // reaches the per-keystroke shell hooks, so the session snapshot must be advanced
        // natively or it stays pre-paste until the next real keystroke (stripping legitimate
        // separator spaces on the next accept and mispositioning the remaining-tail ghost).
        // Shell sessions are addressed by their adapter identity "terminal-<shellPid>"; the
        // TUI's "tui-claude-code-*" elements fall through (no session — the OCR heartbeat
        // refreshes those).
        suggestionCoordinator.onTerminalInsertion = { context, insertedText in
            Self.handleTerminalInsertion(
                context: context,
                insertedText: insertedText,
                terminalIntegrationService: terminalIntegrationService
            )
        }

        // When the user moves from an embedded host's terminal pane to a real AX text field
        // (VS Code editor), the focus model reclaims focus from the injection — the inserter
        // must leave clipboard-paste mode with it or an acceptance in the editor would paste
        // instead of using AX insertion.
        focusModel.onTerminalInjectionReclaimed = {
            suggestionInserter.isTerminalMode = false
        }

        // Debug-only: the E2E harness sends `{"type":"accept"}` over the socket to trigger the
        // real acceptance path. Test automation cannot synthesize a keystroke that CGEvent taps
        // receive (TCC drops cross-process posts), so this is the only scriptable way to exercise
        // accept → clipboard paste end to end. Hard-gated on the debug launch argument.
        terminalIntegrationService.onAcceptRequest = { [weak suggestionCoordinator] in
            Self.handleAcceptRequest(suggestionCoordinator: suggestionCoordinator)
        }

        // When a shell session connects or disconnects, reconcile the coordinator state
        // and clear AX polling suppression so normal focus tracking resumes.
        terminalIntegrationService.onSessionChange = { [weak suggestionCoordinator, weak focusModel] in
            Self.handleSessionChange(
                suggestionCoordinator: suggestionCoordinator,
                focusModel: focusModel,
                terminalIntegrationService: terminalIntegrationService,
                suggestionInserter: suggestionInserter,
                geometryCoordinator: shellPromptGeometryCoordinator
            )
        }

        // Claude Code TUI pipeline (Sub-plan C). The screenshot service (created above, shared
        // with the shell-prompt anchors) owns the ScreenCaptureKit window lookup + region
        // capture; the coordinator owns the debounce + adapter wiring and is fed every
        // keystroke through the `tuiInputObserver` hook below. Both stay no-ops until the
        // user opts in by flipping the experiment flag (default off).
        // The TUI providers deliberately read NSWorkspace (the real frontmost app), NOT the
        // focus model: while a TUI owns the terminal there is no AX text element and no live
        // shell report, so `focusModel.snapshot.context` is nil exactly when Claude Code is
        // the thing on screen.
        let tuiContextCoordinator = TuiContextCoordinator(
            captureSession: { [weak focusModel] in
                try await Self.tuiCaptureSession(focusModel: focusModel, screenshotService: tuiScreenshotService)
            },
            frontmostBundleProvider: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            },
            terminalTitleProvider: {
                // Reading the terminal window's title would require a fresh AX call against the
                // focused window (none of the existing snapshot fields carry it). The
                // process-tree heuristic below is more reliable than a half-correct title, so
                // we return nil here and let the detector fall straight through to processes.
                // A follow-up can wire AXUIElementCopyAttributeValue for kAXTitleAttribute when
                // a terminal's foreground binary doesn't show up in the process tree.
                nil
            },
            foregroundProcessProvider: {
                Self.tuiForegroundProcessNames(terminalIntegrationService: terminalIntegrationService)
            },
            focusChangeSequenceProvider: { [weak focusModel] in
                Self.focusChangeSequence(snapshot: focusModel?.snapshot)
            },
            isEnabled: { [weak permissionManager] in
                Self.isTuiEnabled(settings: suggestionSettings, permissionManager: permissionManager)
            },
            isShellActivelyReporting: {
                Self.isShellActivelyReporting(terminalIntegrationService: terminalIntegrationService)
            },
            injectSnapshot: { [weak focusModel] snapshot in
                let focusSnapshot = FocusSnapshot(
                    applicationName: snapshot.applicationName,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    capability: .supported,
                    context: snapshot,
                    inspection: nil
                )
                focusModel?.injectTerminalSnapshot(focusSnapshot)
                // The TUI path uses the same terminal clipboard-paste insertion as the shell
                // path, so flip the inserter into terminal mode while a Claude Code prompt is
                // live. `onSessionChange` (above) flips it back off when the user steps away.
                suggestionInserter.isTerminalMode = true
            },
            clearInjection: { [weak focusModel] in
                Self.clearTuiInjection(focusModel: focusModel, suggestionInserter: suggestionInserter)
            }
        )
        tuiContextCoordinator.startHeartbeat()
        // Captured by reference in the observer closure below; counts consecutive keystrokes
        // that arrived while the shell snapshot was stale. See the guard inside the closure.
        var staleTerminalKeystrokes = 0
        suggestionCoordinator.tuiInputObserver = { [weak tuiContextCoordinator, weak focusModel] event in
            Self.handleTuiInput(
                event: event,
                tuiContextCoordinator: tuiContextCoordinator,
                deps: TerminalStaleGuardContext(
                    focusModel: focusModel,
                    terminalIntegrationService: terminalIntegrationService,
                    suggestionInserter: suggestionInserter
                ),
                staleTerminalKeystrokes: &staleTerminalKeystrokes
            )
        }

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.appUpdateManager = appUpdateManager
        self.launchAtLoginService = launchAtLoginService
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.clipboardContextProvider = clipboardContextProvider
        self.suggestionCoordinator = suggestionCoordinator
        self.suggestionEngine = suggestionEngine
        self.emojiPickerController = emojiPickerController
        self.emojiUsageStore = emojiUsageStore
        self.welcomeCoordinator = welcomeCoordinator
        self.huggingFaceSearchService = huggingFaceSearchService
        self.performanceMetricsStore = performanceMetricsStore
        self.settingsCoordinator = settingsCoordinator
        self.activationIndicatorController = activationIndicatorController
        self.focusDebugOverlayController = FocusDebugOverlayController.isEnabled
            ? FocusDebugOverlayController()
            : nil
        self.terminalIntegrationService = terminalIntegrationService
        self.tuiScreenshotService = tuiScreenshotService
        self.tuiContextCoordinator = tuiContextCoordinator
        self.shellPromptGeometryCoordinator = shellPromptGeometryCoordinator

        // Legacy `terminal-suggestion.txt` file-based acceptance was replaced by the
        // `SuggestionInserter` terminal mode's clipboard-paste path in B.3 of
        // `docs/plan-terminal-claude-code-and-per-app-shortcuts.md`. Cotabby now consumes the
        // terminal accept keystroke (see `shouldPassThroughAcceptKeyProvider = { false }` above)
        // and inserts via Cmd+V into the shell's bracketed-paste handler, which unifies all
        // surfaces on a single code path and removes the file-poll race with the shell widget.
        //
        // Stale suggestion files from a previous build can confuse the shell-side fallback
        // widget (which still exists as a documented backstop), so we sweep one on launch.
        let legacySuggestionFilePath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Cotabby/terminal-suggestion.txt").path
        try? FileManager.default.removeItem(atPath: legacySuggestionFilePath)

        // Update the AX polling timer whenever the user changes the poll interval setting.
        suggestionSettings.$focusPollIntervalMilliseconds
            .removeDuplicates()
            .sink { [weak focusModel] milliseconds in
                focusModel?.updatePollInterval(milliseconds: milliseconds)
            }
            .store(in: &cancellables)

        // Key code changes reach InputMonitor through closures that read from the model
        // at event time (set above), so no Combine subscription is needed here.

        // The global-toggle hotkey is the exception: its tap is install-on-demand so a user who
        // never binds it pays zero per-keystroke cost. Install/uninstall whenever the binding
        // crosses the unbound/bound boundary or when the key code itself changes.
        suggestionSettings.$globalToggleKeyCode
            .removeDuplicates()
            .sink { [weak inputMonitor] _ in
                inputMonitor?.refreshToggleTap()
            }
            .store(in: &cancellables)
    }
}

/// Capture region for a terminal screenshot, shared by the Claude Code TUI and shell-prompt
/// capture closures. Dedicated terminals use the whole window. Embedded-terminal hosts
/// (VS Code etc.) constrain to the focused pane's AX frame when one exists — full-window OCR
/// there reads editor chrome ("> Connect to…" welcome links, tab labels) as prompt content —
/// and fall back to the window when AX has nothing usable (tiny/foreign element, no focus,
/// which is the NORMAL state for the AX-dead integrated terminal).
@MainActor
private func embeddedHostCaptureRegion(
    windowFrame: CGRect,
    pid: pid_t,
    bundleIdentifier: String
) -> CGRect {
    guard TerminalAppDetector.hostsEmbeddedTerminal(bundleIdentifier: bundleIdentifier),
          let focusedElement = AXHelper.focusedElement(forApplicationPID: pid),
          let paneFrame = AXHelper.rectValue(for: "AXFrame" as CFString, on: focusedElement)
    else { return windowFrame }
    let clamped = paneFrame.intersection(windowFrame)
    guard clamped.height > 60, clamped.width > 200 else { return windowFrame }
    return clamped
}

/// Bundles the long-lived terminal dependencies the stale-shell guard reads and mutates, so the
/// extracted `handleTuiInput` helper stays within the parameter-count budget. Built per-call from
/// the observer's `[weak focusModel]` capture, so it never retains the focus model beyond the call.
private struct TerminalStaleGuardContext {
    let focusModel: FocusTrackingModel?
    let terminalIntegrationService: TerminalIntegrationService
    let suggestionInserter: SuggestionInserter
}

/// Branch-heavy bodies extracted out of `init()` so the composition root stays under SwiftLint's
/// cyclomatic-complexity cap. Each helper is a pure forward of the closure body it replaced —
/// behavior is unchanged; only the decision points moved off the initializer.
@MainActor
private extension CotabbyAppEnvironment {
    /// Stop the deep AX walk when Cotabby is globally off or disabled for the focused app, so the
    /// focus poll stops touching the frontmost app's AX attributes (see #476).
    static func isCaptureSuppressed(bundleIdentifier: String?, settings: SuggestionSettingsModel) -> Bool {
        guard settings.isGloballyEnabled else { return true }
        if let bundleIdentifier,
           settings.isApplicationDisabled(bundleIdentifier: bundleIdentifier) {
            return true
        }
        return false
    }

    static func shouldProcessEvents(
        snapshot: FocusSnapshot?,
        settings: SuggestionSettingsModel,
        terminalIntegrationService: TerminalIntegrationService
    ) -> Bool {
        guard settings.isGloballyEnabled else { return false }
        guard let snapshot else { return true }
        // Allow input processing for terminals with either an active shell-integration session OR
        // the Claude Code TUI experiment on. The TUI path needs the listen-only observer to fire
        // on every keystroke so the OCR coordinator can debounce a refresh — gating on shell-only
        // would silently disable Claude Code autocomplete even with the experiment switched on.
        if TerminalAppDetector.isTerminal(bundleIdentifier: snapshot.bundleIdentifier) {
            guard let bid = snapshot.bundleIdentifier else { return false }
            let shellActive = settings.isTerminalIntegrationEnabled
                && terminalIntegrationService.hasActiveSession(forBundleIdentifier: bid)
            let tuiActive = settings.isClaudeCodeTuiExperimentEnabled
            return shellActive || tuiActive
        }
        if let bundleID = snapshot.bundleIdentifier,
           settings.isApplicationDisabled(bundleIdentifier: bundleID) {
            return false
        }
        return true
    }

    /// Single source of truth for "the user is typing into a shell": dedicated terminals always;
    /// embedded-terminal hosts only while one of their shells holds a live integration session.
    static func isShellSurface(
        bundleIdentifier: String?,
        terminalIntegrationService: TerminalIntegrationService
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        if TerminalAppDetector.isTerminal(bundleIdentifier: bundleIdentifier) { return true }
        return TerminalAppDetector.hostsEmbeddedTerminal(bundleIdentifier: bundleIdentifier)
            && terminalIntegrationService.hasActiveSession(forBundleIdentifier: bundleIdentifier)
    }

    /// Terminal-aware accept key code. Precedence: terminal binding on any shell surface, else the
    /// per-app/global resolver. `isShellSurface` is resolved by the caller from the live snapshot.
    static func terminalAwareAcceptanceKeyCode(
        bundleIdentifier: String?,
        isShellSurface: Bool,
        settings: SuggestionSettingsModel
    ) -> CGKeyCode {
        if isShellSurface, settings.isTerminalIntegrationEnabled {
            return settings.terminalAcceptanceKeyCode
        }
        return ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: bundleIdentifier,
            overrides: settings.perAppShortcutOverrides,
            globalKeyCode: settings.acceptanceKeyCode,
            globalModifiers: settings.acceptanceKeyModifiers,
            globalLabel: settings.acceptanceKeyLabel
        ).keyCode
    }

    static func terminalAwareAcceptanceKeyModifiers(
        bundleIdentifier: String?,
        isShellSurface: Bool,
        settings: SuggestionSettingsModel
    ) -> ShortcutModifierMask {
        if isShellSurface, settings.isTerminalIntegrationEnabled {
            return settings.terminalAcceptanceKeyModifiers
        }
        return ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: bundleIdentifier,
            overrides: settings.perAppShortcutOverrides,
            globalKeyCode: settings.acceptanceKeyCode,
            globalModifiers: settings.acceptanceKeyModifiers,
            globalLabel: settings.acceptanceKeyLabel
        ).modifiers
    }

    static func observeEmoji(event: CapturedInputEvent, controller: EmojiPickerController?) -> Bool {
        controller?.observe(event) ?? false
    }

    static func isTerminalIntegrationActive(
        snapshot: FocusSnapshot?,
        settings: SuggestionSettingsModel,
        terminalIntegrationService: TerminalIntegrationService
    ) -> Bool {
        // A TUI-injected snapshot reaches the focus model with the `ClaudeCodeTuiInput` role;
        // checking the live snapshot keeps this in lockstep with whatever source last updated
        // focus. Checked before the terminal-app gate because the TUI path also serves
        // embedded-terminal hosts (VS Code), which are NOT in the dedicated-terminal list.
        if settings.isClaudeCodeTuiExperimentEnabled,
           snapshot?.context?.role == "ClaudeCodeTuiInput" {
            return true
        }
        guard let bid = snapshot?.bundleIdentifier else { return false }
        guard TerminalAppDetector.isTerminal(bundleIdentifier: bid) else { return false }
        return settings.isTerminalIntegrationEnabled
            && terminalIntegrationService.hasActiveSession(forBundleIdentifier: bid)
    }

    /// OCR prompt-anchor capture for shell surfaces. The debounced capture can fire after an app
    /// switch — only shoot the screen while the reporting terminal is still frontmost.
    static func shellCaptureSession(
        snapshot: TerminalFocusSnapshot,
        screenshotService: TuiScreenshotService
    ) async throws -> ShellPromptGeometryCoordinator.CaptureResult? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == snapshot.terminalBundleIdentifier
        else { return nil }
        let pid = app.processIdentifier
        guard let windowFrame = try await screenshotService.windowFrame(forPid: pid) else {
            return nil
        }
        let region = embeddedHostCaptureRegion(
            windowFrame: windowFrame,
            pid: pid,
            bundleIdentifier: snapshot.terminalBundleIdentifier
        )
        guard let image = try await screenshotService.captureRegion(forPid: pid, region: region) else {
            return nil
        }
        return ShellPromptGeometryCoordinator.CaptureResult(
            region: region,
            windowFrame: windowFrame,
            image: image
        )
    }

    static func shellWindowFrame(snapshot: TerminalFocusSnapshot) -> CGRect? {
        guard let pid = TerminalGeometryResolver.terminalAppPid(
            forBundleIdentifier: snapshot.terminalBundleIdentifier
        ) else { return nil }
        return TerminalGeometryResolver.windowFrame(forPid: pid)
    }

    /// ScreenCaptureKit needs Screen Recording; without it the coordinator stays inert and shell
    /// surfaces show no ghost (suppressed caret), the same gate the TUI path uses.
    static func screenRecordingGranted(permissionManager: PermissionManager?) -> Bool {
        permissionManager?.screenRecordingGranted ?? false
    }

    /// When a shell hook reports buffer state, enrich it with geometry and inject it into the focus
    /// model so the suggestion pipeline sees terminal input like any other field. Shared by the live
    /// report path AND the anchor-resolved re-injection.
    static func handleShellReport(
        _ rawSnapshot: TerminalFocusSnapshot,
        focusModel: FocusTrackingModel?,
        suggestionInserter: SuggestionInserter,
        geometryCoordinator: ShellPromptGeometryCoordinator
    ) {
        // Only the frontmost terminal's shells may drive focus. Several hooked shells can be alive
        // at once (other windows, other terminal apps), and their heartbeat reports would otherwise
        // hijack the focus model and cancel in-flight generations for the terminal in use.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == rawSnapshot.terminalBundleIdentifier else { return }
        // Embedded-terminal hosts (VS Code etc.) own real AX text fields in the SAME bundle
        // (editor, search, Cmd+P) — those must keep AX service. But the integrated terminal itself
        // is an xterm.js canvas that exposes NO focused AX element, so the shell hook is the ONLY
        // input source there. Inject unless a supported AX element currently owns focus;
        // terminal-role snapshots are our own injections and never block a fresh report.
        if TerminalAppDetector.hostsEmbeddedTerminal(
            bundleIdentifier: rawSnapshot.terminalBundleIdentifier
        ) {
            let current = focusModel?.snapshot
            let role = current?.context?.role
            let axOwnsFocus = current?.bundleIdentifier == rawSnapshot.terminalBundleIdentifier
                && current?.capability == .supported
                && role != "TerminalShellInput"
                && role != "ClaudeCodeTuiInput"
            if axOwnsFocus { return }
        }
        suggestionInserter.isTerminalMode = true
        // May schedule a debounced OCR pass (new prompt / invalidated anchor); cheap no-op while a
        // valid anchor serves this shell.
        geometryCoordinator.snapshotReported(rawSnapshot)
        let enriched: TerminalFocusSnapshot
        if let resolved = geometryCoordinator.geometry(for: rawSnapshot) {
            enriched = rawSnapshot.withGeometry(
                windowFrame: resolved.windowFrame,
                cursorRect: resolved.caretRect,
                promptLineRect: resolved.inputLineRect,
                observedCellWidth: resolved.cellWidth
            )
        } else {
            // No anchor (yet): legacy enrichment carries the window frame for context but produces
            // NO caret — the overlay stays hidden rather than guessing, and the onAnchorResolved
            // re-injection snaps it in moments later.
            enriched = TerminalGeometryResolver.enrichWithGeometry(rawSnapshot)
        }
        let adapted = TerminalFocusAdapter.adapt(
            enriched,
            terminalPid: TerminalGeometryResolver.terminalAppPid(
                forBundleIdentifier: enriched.terminalBundleIdentifier
            ),
            focusChangeSequence: UInt64(enriched.shellPid)
        )
        let focusSnapshot = FocusSnapshot(
            applicationName: adapted.applicationName,
            bundleIdentifier: adapted.bundleIdentifier,
            capability: .supported,
            context: adapted,
            inspection: nil
        )
        focusModel?.injectTerminalSnapshot(focusSnapshot)
    }

    /// Re-run the report path with the shell's LATEST buffer once a fresh anchor lands, so the ghost
    /// snaps from hidden to positioned without waiting for the next keystroke.
    static func reinjectLatestSnapshot(
        shellPid: Int32,
        focusModel: FocusTrackingModel?,
        suggestionInserter: SuggestionInserter,
        geometryCoordinator: ShellPromptGeometryCoordinator,
        terminalIntegrationService: TerminalIntegrationService
    ) {
        guard let latest = terminalIntegrationService.latestSnapshot(forPid: shellPid) else { return }
        handleShellReport(
            latest,
            focusModel: focusModel,
            suggestionInserter: suggestionInserter,
            geometryCoordinator: geometryCoordinator
        )
    }

    /// Optimistic local echo after Cotabby's own terminal paste — bracketed paste never reaches the
    /// per-keystroke shell hooks, so the session snapshot must be advanced natively. Shell sessions
    /// are addressed by adapter identity "terminal-<shellPid>"; TUI elements fall through.
    static func handleTerminalInsertion(
        context: FocusedInputContext,
        insertedText: String,
        terminalIntegrationService: TerminalIntegrationService
    ) {
        let prefix = "terminal-"
        guard context.elementIdentifier.hasPrefix(prefix),
              let shellPid = Int32(context.elementIdentifier.dropFirst(prefix.count)) else { return }
        terminalIntegrationService.applyOptimisticInsertion(
            shellPid: shellPid,
            insertedText: insertedText
        )
    }

    /// Debug-only accept path for the E2E harness: test automation cannot synthesize a keystroke
    /// that CGEvent taps receive, so the socket message drives acceptance directly. Hard-gated on
    /// the debug launch argument.
    static func handleAcceptRequest(suggestionCoordinator: SuggestionCoordinator?) {
        guard CotabbyDebugOptions.isEnabled else { return }
        _ = suggestionCoordinator?.acceptCurrentSuggestion()
    }

    /// Reconcile coordinator state when a shell session connects or disconnects and clear AX polling
    /// suppression so normal focus tracking resumes.
    static func handleSessionChange(
        suggestionCoordinator: SuggestionCoordinator?,
        focusModel: FocusTrackingModel?,
        terminalIntegrationService: TerminalIntegrationService,
        suggestionInserter: SuggestionInserter,
        geometryCoordinator: ShellPromptGeometryCoordinator
    ) {
        if terminalIntegrationService.sessions.isEmpty {
            focusModel?.clearTerminalInjection()
            suggestionInserter.isTerminalMode = false
            geometryCoordinator.invalidateAll()
        } else {
            geometryCoordinator.prune(keeping: terminalIntegrationService.sessions.keys)
        }
        suggestionCoordinator?.reconcileWithCurrentEnvironment()
    }

    /// Claude Code TUI capture. Reads NSWorkspace (the real frontmost app), NOT the focus model:
    /// while a TUI owns the terminal there is no AX text element and no live shell report.
    static func tuiCaptureSession(
        focusModel: FocusTrackingModel?,
        screenshotService: TuiScreenshotService
    ) async throws -> TuiContextCoordinator.CaptureResult? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier,
              TerminalAppDetector.isTerminal(bundleIdentifier: bid)
                || TerminalAppDetector.hostsEmbeddedTerminal(bundleIdentifier: bid)
        else { return nil }
        if tuiShouldSkipForEditor(bundleIdentifier: bid, snapshot: focusModel?.snapshot) {
            return nil
        }
        let pid = app.processIdentifier
        guard let windowFrame = try await screenshotService.windowFrame(forPid: pid) else {
            return nil
        }
        // Capture the WHOLE window, not a bottom band: Claude Code anchors its input box under the
        // conversation content, so in a fresh/short session the editable line sits near the TOP of
        // the window and a bottom crop misses it entirely. Embedded hosts get pane-constrained
        // capture — see embeddedHostCaptureRegion.
        let region = embeddedHostCaptureRegion(
            windowFrame: windowFrame,
            pid: pid,
            bundleIdentifier: bid
        )
        guard let image = try await screenshotService.captureRegion(forPid: pid, region: region) else {
            return nil
        }
        let descriptor = TuiContextCoordinator.TerminalWindowDescriptor(
            windowFrame: windowFrame,
            pid: pid,
            bundleIdentifier: bid,
            applicationName: app.localizedName ?? "Terminal"
        )
        return TuiContextCoordinator.CaptureResult(descriptor: descriptor, region: region, image: image)
    }

    /// Same editor-protection rule as the shell-injection path: in an embedded host a supported,
    /// non-terminal-role snapshot means a real AX text field (the editor) owns focus, and OCR-
    /// injecting over it would hijack the editor (re-arming an inject/reclaim flicker loop).
    static func tuiShouldSkipForEditor(bundleIdentifier: String, snapshot: FocusSnapshot?) -> Bool {
        guard TerminalAppDetector.hostsEmbeddedTerminal(bundleIdentifier: bundleIdentifier),
              let current = snapshot,
              current.bundleIdentifier == bundleIdentifier,
              current.capability == .supported,
              current.context?.role != "TerminalShellInput",
              current.context?.role != "ClaudeCodeTuiInput"
        else { return false }
        return true
    }

    /// Walk the descendants of the frontmost app's process so the detector can spot `claude` /
    /// `claude-code` even when the terminal strips OSC titles. Embedded hosts walk only the hooked
    /// shell sessions' subtrees, so extension-host `claude` processes don't produce false positives.
    static func tuiForegroundProcessNames(terminalIntegrationService: TerminalIntegrationService) -> [String] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        guard let bid = app.bundleIdentifier,
              TerminalAppDetector.hostsEmbeddedTerminal(bundleIdentifier: bid) else {
            return ProcessTreeInspector.descendantProcessNames(of: app.processIdentifier)
        }
        let shellPids = terminalIntegrationService.sessions.values
            .filter { $0.terminalBundleIdentifier == bid }
            .map(\.shellPid)
        guard !shellPids.isEmpty else { return [] }
        return ProcessTreeInspector.subtreeProcessNames(rootedAt: shellPids)
    }

    static func focusChangeSequence(snapshot: FocusSnapshot?) -> UInt64 {
        snapshot?.context?.focusChangeSequence ?? 0
    }

    /// Screen Recording is the load-bearing permission for ScreenCaptureKit. Cutting the loop here
    /// means a user who hasn't granted it never sees ScreenCaptureKit throw on every keystroke.
    static func isTuiEnabled(settings: SuggestionSettingsModel, permissionManager: PermissionManager?) -> Bool {
        guard settings.isClaudeCodeTuiExperimentEnabled else { return false }
        return permissionManager?.screenRecordingGranted ?? false
    }

    /// "Fresh" = the frontmost app's shell reported a buffer within the last 2 s, i.e. keystrokes
    /// are reaching a bare prompt — shell-prompt source owns input there and the TUI path yields.
    static func isShellActivelyReporting(terminalIntegrationService: TerminalIntegrationService) -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let latest = terminalIntegrationService.latestSnapshot(forBundleIdentifier: bid)
        else { return false }
        return Date().timeIntervalSince(latest.timestamp) < 2.0
    }

    /// A TUI-initiated clear must verify the live snapshot is actually TUI-owned — otherwise the
    /// claude-exit heartbeat would tear down a healthy shell prompt session the SHELL path injected.
    static func clearTuiInjection(focusModel: FocusTrackingModel?, suggestionInserter: SuggestionInserter) {
        let role = focusModel?.snapshot.context?.role
        guard role != "TerminalShellInput" else { return }
        if role == "ClaudeCodeTuiInput" {
            focusModel?.clearTerminalInjection()
        }
        // Reset insertion mode even when focus already moved on — a lingering true would
        // clipboard-paste into normal AX fields.
        suggestionInserter.isTerminalMode = false
    }

    /// Stale shell-buffer guard (Sub-plan D precedence). While a TUI owns the tty, the shell hook is
    /// suspended and its last buffer report freezes, but the injected snapshot would keep serving
    /// that stale text. Three consecutive stale keystrokes are required so the first key after an
    /// idle pause (whose hook report lands just after the tap fires) never clears a live session.
    static func handleTuiInput(
        event: CapturedInputEvent,
        tuiContextCoordinator: TuiContextCoordinator?,
        deps: TerminalStaleGuardContext,
        staleTerminalKeystrokes: inout Int
    ) {
        // Only text-mutation events warrant a refresh — selection moves, modifier-only presses,
        // etc. would burn the OCR latency budget without changing the prompt.
        guard event.kind == .textMutation || event.kind == .shortcutMutation else { return }
        tuiContextCoordinator?.keystrokeObserved()

        if let context = deps.focusModel?.snapshot.context,
           context.role == "TerminalShellInput",
           let bundleIdentifier = deps.focusModel?.snapshot.bundleIdentifier {
            let lastReport = deps.terminalIntegrationService
                .latestSnapshot(forBundleIdentifier: bundleIdentifier)?.timestamp
            let age = lastReport.map { Date().timeIntervalSince($0) } ?? .infinity
            if age > 2.0 {
                staleTerminalKeystrokes += 1
                if staleTerminalKeystrokes >= 3 {
                    staleTerminalKeystrokes = 0
                    deps.focusModel?.clearTerminalInjection()
                    // Leaving terminal-sourced focus must also leave clipboard-paste insertion, or
                    // the next acceptance in a normal AX field pastes.
                    deps.suggestionInserter.isTerminalMode = false
                }
            } else {
                staleTerminalKeystrokes = 0
            }
        } else {
            staleTerminalKeystrokes = 0
        }
    }
}
