import SwiftUI

/// File overview:
/// Composes Tabby's primary menu-bar control panel.
/// This view owns the small amount of presentation logic needed to translate live app state into
/// one compact, product-facing status line, while the section helpers in `MenuBarSections.swift`
/// stay focused on native layout.
struct MenuBarView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var focusModel: FocusTrackingModel
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator

    /// The panel should answer a product question, not dump internals:
    /// "what is the single most important reason Tabby is or is not ready right now?"
    private var statusText: String {
        if !permissionManager.accessibilityGranted || !permissionManager.inputMonitoringGranted {
            return "Permissions Required"
        }

        if runtimeModel.availableModels.isEmpty {
            return "Model Missing"
        }

        switch runtimeModel.state {
        case .starting, .loading, .failed:
            return runtimeModel.state.summary
        case .ready:
            if case .supported = focusModel.snapshot.capability {
                return "Ready"
            }

            return focusModel.menuBarStatusText
        case .idle:
            return focusModel.menuBarStatusText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MenuBarHeaderView()

            MenuBarStatusRow(statusText: statusText)

            Divider()

            MenuBarPermissionsSection(permissionManager: permissionManager)

            MenuBarRuntimeSection(
                runtimeModel: runtimeModel,
                modelDownloadManager: modelDownloadManager
            )

            MenuBarSuggestionControlsSection(suggestionCoordinator: suggestionCoordinator)

            Divider()

            MenuBarFooterRow()
        }
        .padding(18)
        .frame(width: 396)
    }
}
