import AppKit
import SwiftUI

/// File overview:
/// Houses the small, reusable SwiftUI sections that make up Tabby's menu-bar panel.
/// The important design choice in this file is that it stays view-focused: these types lay out
/// already-derived state, while higher-level status decisions live in `MenuBarView`.

private enum MenuBarLayoutMetrics {
    /// One shared label width keeps the form-like rows aligned without inventing custom styling.
    /// The width is only large enough to fit "Autocomplete Length" cleanly in the current menu.
    static let labelColumnWidth: CGFloat = 142
}

struct MenuBarHeaderView: View {
    var body: some View {
        Text("Tabby")
            .font(.headline)
    }
}

struct MenuBarStatusRow: View {
    let statusText: String

    var body: some View {
        MenuBarLabeledRow(title: "Status") {
            Text(statusText)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MenuBarPermissionsSection: View {
    @ObservedObject var permissionManager: PermissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PermissionStatusRow(
                title: "Accessibility",
                granted: permissionManager.accessibilityGranted
            )

            PermissionStatusRow(
                title: "Input Monitoring",
                granted: permissionManager.inputMonitoringGranted
            )

            PermissionStatusRow(
                title: "Screen Recording",
                granted: permissionManager.screenRecordingGranted
            )
        }
    }
}

struct MenuBarRuntimeSection: View {
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    let modelDownloadManager: ModelDownloadManager

    var body: some View {
        MenuBarLabeledRow(title: "Model") {
            HStack(alignment: .center, spacing: 8) {
                modelSelector

                // These stay inline with the picker so the menu exposes the two model-management
                // actions the user actually needs without reviving the old download/debug section.
                Button {
                    modelDownloadManager.openModelsDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("Open Models Folder")

                Button {
                    modelDownloadManager.refreshModelStates()
                    runtimeModel.refreshAvailableModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Refresh Models")
            }
        }
    }

    @ViewBuilder
    private var modelSelector: some View {
        if runtimeModel.availableModels.isEmpty {
            Text("No local GGUF models found")
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("Model", selection: selectedModelBinding) {
                ForEach(runtimeModel.availableModels) { model in
                    Text(model.displayName)
                        .tag(model.filename)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(runtimePickerDisabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                runtimeModel.selectedModelFilename
                    ?? runtimeModel.availableModels.first?.filename
                    ?? ""
            },
            set: { filename in
                Task {
                    await runtimeModel.selectModel(filename)
                }
            }
        )
    }

    private var runtimePickerDisabled: Bool {
        switch runtimeModel.state {
        case .starting, .loading:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }
}

struct MenuBarSuggestionControlsSection: View {
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SuggestionWordCountPickerRow(
                title: "Autocomplete Length",
                selection: wordCountPresetBinding,
                options: SuggestionWordCountPreset.allCases
            )

            SuggestionPromptModePickerRow(
                title: "Prompt",
                selection: promptModeBinding,
                options: SuggestionPromptMode.allCases
            )
        }
    }

    private var wordCountPresetBinding: Binding<SuggestionWordCountPreset> {
        Binding(
            get: { suggestionCoordinator.selectedWordCountPreset },
            set: { preset in
                suggestionCoordinator.selectWordCountPreset(preset)
            }
        )
    }

    private var promptModeBinding: Binding<SuggestionPromptMode> {
        Binding(
            get: { suggestionCoordinator.selectedPromptMode },
            set: { mode in
                suggestionCoordinator.selectPromptMode(mode)
            }
        )
    }
}

struct MenuBarFooterRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Button(action: {}) {
                Label("Settings", systemImage: "gearshape")
            }
            .controlSize(.small)

            Spacer(minLength: 0)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Tabby", systemImage: "xmark.circle")
            }
            .keyboardShortcut("q")
            .controlSize(.small)
        }
    }
}

private struct MenuBarLabeledRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: MenuBarLayoutMetrics.labelColumnWidth, alignment: .leading)

            content
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let granted: Bool

    var body: some View {
        MenuBarLabeledRow(title: title) {
            Text(granted ? "Granted" : "Not Granted")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SuggestionWordCountPickerRow: View {
    let title: String
    let selection: Binding<SuggestionWordCountPreset>
    let options: [SuggestionWordCountPreset]

    var body: some View {
        MenuBarLabeledRow(title: title) {
            Picker(title, selection: selection) {
                ForEach(options) { preset in
                    Text(preset.displayLabel)
                        .tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SuggestionPromptModePickerRow: View {
    let title: String
    let selection: Binding<SuggestionPromptMode>
    let options: [SuggestionPromptMode]

    var body: some View {
        MenuBarLabeledRow(title: title) {
            Picker(title, selection: selection) {
                ForEach(options) { mode in
                    Text(mode.displayLabel)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
