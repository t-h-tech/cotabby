import SwiftUI

/// File overview:
/// Composes the menu bar panel from smaller section views. The root view now focuses on layout and
/// wiring, while formatting and section-specific rendering live in dedicated UI files.
struct MenuBarView: View {
    @ObservedObject var permissionManager: PermissionManager
    /// `@ObservedObject` listens to an external owner; the model lifetime is not owned by this view.
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var focusModel: FocusTrackingModel
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator
    let welcomeCoordinator: WelcomeCoordinator

    private var presentation: MenuBarPresentation {
        MenuBarPresentation.make(
            runtimeModel: runtimeModel,
            focusModel: focusModel,
            suggestionCoordinator: suggestionCoordinator
        )
    }

    var body: some View {
        let presentation = presentation

        VStack(alignment: .leading, spacing: 12) {
            MenuBarHeaderView(header: presentation.header)

            MenuBarPermissionsSection(permissionManager: permissionManager)

            MenuBarRuntimeSection(
                runtimeModel: runtimeModel,
                modelDownloadManager: modelDownloadManager
            )

            MenuBarSuggestionControlsSection(suggestionCoordinator: suggestionCoordinator)

            MenuBarStatusSection(presentation: presentation)

            MenuBarDebugSection(previews: presentation.debugPreviews)

            Divider()

            MenuBarActionsRow(welcomeCoordinator: welcomeCoordinator)
        }
        .padding(12)
        .frame(width: 320)
    }
}
