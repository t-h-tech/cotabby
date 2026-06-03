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
        inputMonitor.fullAcceptanceKeyCodeProvider = { suggestionSettings.fullAcceptanceKeyCode }
        inputMonitor.fullAcceptanceKeyModifiersProvider = { suggestionSettings.fullAcceptanceKeyModifiers }
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
                guard suggestionSettings.isGloballyEnabled else { return true }
                if let bundleIdentifier,
                   suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleIdentifier) {
                    return true
                }
                return false
            },
            publishesPollingEvents: FocusDebugOverlayController.isEnabled
        )
        // The snapshot is poll-based, so after a fast app switch the closure may briefly
        // evaluate against the previous app's identity until the next AX poll fires. This
        // is the same race the downstream evaluator already has — not a new regression.

        inputMonitor.shouldProcessEventsProvider = { [weak focusModel] in
            guard suggestionSettings.isGloballyEnabled else { return false }
            guard let snapshot = focusModel?.snapshot else { return true }
            // Allow input processing for terminals with active shell integration.
            if TerminalAppDetector.isTerminal(bundleIdentifier: snapshot.bundleIdentifier) {
                guard let bid = snapshot.bundleIdentifier,
                      suggestionSettings.isTerminalIntegrationEnabled,
                      terminalIntegrationService.hasActiveSession(forBundleIdentifier: bid) else {
                    return false
                }
                return true
            }
            if let bundleID = snapshot.bundleIdentifier,
               suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleID) {
                return false
            }
            return true
        }
        // Now that focusModel and terminalIntegrationService exist, set the terminal-aware
        // acceptance key providers. When a terminal with shell integration is focused, the
        // acceptance key swaps to the terminal-specific binding (Option+Tab by default).
        inputMonitor.acceptanceKeyCodeProvider = { [weak focusModel] in
            if let bid = focusModel?.snapshot.bundleIdentifier,
               TerminalAppDetector.isTerminal(bundleIdentifier: bid),
               suggestionSettings.isTerminalIntegrationEnabled {
                return suggestionSettings.terminalAcceptanceKeyCode
            }
            return suggestionSettings.acceptanceKeyCode
        }
        inputMonitor.acceptanceKeyModifiersProvider = { [weak focusModel] in
            if let bid = focusModel?.snapshot.bundleIdentifier,
               TerminalAppDetector.isTerminal(bundleIdentifier: bid),
               suggestionSettings.isTerminalIntegrationEnabled {
                return suggestionSettings.terminalAcceptanceKeyModifiers
            }
            return suggestionSettings.acceptanceKeyModifiers
        }
        // In terminals, let the acceptance keystroke pass through so the shell hook's zle widget
        // can see it and insert the text into zsh's BUFFER.
        inputMonitor.shouldPassThroughAcceptKeyProvider = { [weak focusModel] in
            guard let bid = focusModel?.snapshot.bundleIdentifier else { return false }
            return TerminalAppDetector.isTerminal(bundleIdentifier: bid)
                && suggestionSettings.isTerminalIntegrationEnabled
        }
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
            emojiPickerController?.observe(event) ?? false
        }

        // Terminal integration: tell the coordinator how to check for active shell sessions.
        suggestionCoordinator.terminalIntegrationActiveProvider = { [weak focusModel] in
            guard suggestionSettings.isTerminalIntegrationEnabled else { return false }
            guard let bid = focusModel?.snapshot.bundleIdentifier else { return false }
            return TerminalAppDetector.isTerminal(bundleIdentifier: bid)
                && terminalIntegrationService.hasActiveSession(forBundleIdentifier: bid)
        }

        // When a shell hook reports buffer state, enrich it with geometry and inject it into
        // the focus model so the suggestion pipeline sees terminal input like any other field.
        terminalIntegrationService.onSnapshotUpdate = { [weak focusModel] rawSnapshot in
            suggestionInserter.isTerminalMode = true
            let enriched = TerminalGeometryResolver.enrichWithGeometry(rawSnapshot)
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

        // When a shell session connects or disconnects, reconcile the coordinator state
        // and clear AX polling suppression so normal focus tracking resumes.
        terminalIntegrationService.onSessionChange = { [weak suggestionCoordinator, weak focusModel] in
            if terminalIntegrationService.sessions.isEmpty {
                focusModel?.clearTerminalInjection()
                suggestionInserter.isTerminalMode = false
            }
            suggestionCoordinator?.reconcileWithCurrentEnvironment()
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

        // Write the current suggestion to a file so the shell hook can read and insert it
        // when the user presses right-arrow. This bypasses CGEvent tap issues in terminals.
        let suggestionFilePath = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Cotabby/terminal-suggestion.txt").path

        suggestionCoordinator.onSuggestionReadyChanged = { [weak focusModel] suggestion in
            // Write the suggestion file whenever the focused app is a terminal with an active
            // shell integration session. The zsh hook reads this file when right-arrow is pressed.
            // Check by bundle ID + active session rather than isTerminalMode or element ID,
            // because the AX pipeline may handle Ghostty with a non-terminal element ID.
            let bid = focusModel?.snapshot.bundleIdentifier
            let isTerminal = bid.map { TerminalAppDetector.isTerminal(bundleIdentifier: $0) } ?? false

            if isTerminal, let text = suggestion, !text.isEmpty {
                try? text.write(toFile: suggestionFilePath, atomically: true, encoding: .utf8)
            } else if !isTerminal {
                // Only delete the file when NOT in a terminal. In terminals, the zsh hook's
                // forward-char widget reads and deletes the file after inserting the text.
                // Deleting here would race with the widget and prevent acceptance.
                try? FileManager.default.removeItem(atPath: suggestionFilePath)
            }
        }

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
