import AppKit
import SwiftUI

/// File overview:
/// Houses the smaller SwiftUI sections that make up the menu bar panel. Breaking the panel into
/// sections keeps each view focused on one concern: permissions, runtime controls, suggestion
/// settings, status readouts, debug previews, or top-level actions.

struct MenuBarHeaderView: View {
    let header: MenuBarHeaderPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: header.iconSymbolName)
                    .font(.title3)
                    .foregroundStyle(header.tone.color)

                Text("\(header.acceptedWordCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Tabby")
                    .font(.headline)

                Text("Input \(header.inputStatusText)")
                    .font(.subheadline)
                    .foregroundStyle(header.tone.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }
}

struct MenuBarPermissionsSection: View {
    @ObservedObject var permissionManager: PermissionManager

    private var showsPermissionActions: Bool {
        !permissionManager.accessibilityGranted
            || !permissionManager.inputMonitoringGranted
            || !permissionManager.screenRecordingGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                granted: permissionManager.screenRecordingGranted,
                missingLabel: "Optional"
            )

            if showsPermissionActions {
                permissionActions
            }
        }
    }

    @ViewBuilder
    private var permissionActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !permissionManager.accessibilityGranted {
                Button("Open Accessibility") {
                    permissionManager.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if !permissionManager.inputMonitoringGranted {
                Button("Open Input Monitoring") {
                    permissionManager.openInputMonitoringSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if !permissionManager.screenRecordingGranted {
                Button("Open Screen Recording") {
                    permissionManager.openScreenRecordingSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}

struct MenuBarRuntimeSection: View {
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if runtimeModel.availableModels.isEmpty {
                CompactStatusRow(
                    title: "Model",
                    value: "No local GGUF models found",
                    tone: .secondary
                )
            } else {
                ModelPickerRow(
                    title: "Model",
                    selection: selectedModelBinding,
                    models: runtimeModel.availableModels,
                    isDisabled: runtimePickerDisabled
                )
            }

            if !modelDownloadManager.models.isEmpty {
                modelDownloadSection
            }
        }
    }

    private var modelDownloadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text("Models")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 74, alignment: .leading)

                Text("Download on demand")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(modelDownloadManager.models) { model in
                        let state = modelDownloadManager.state(for: model)

                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(state.statusText)
                                    .font(.caption2)
                                    .foregroundStyle(modelDownloadStatusColor(for: state))
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Button(downloadButtonTitle(for: state)) {
                                modelDownloadManager.download(model)
                            }
                            .controlSize(.small)
                            .disabled(isDownloadButtonDisabled(for: state))
                        }
                    }
                }
            }
            .frame(maxHeight: 120)

            HStack(spacing: 8) {
                Button("Open Folder") {
                    modelDownloadManager.openModelsDirectory()
                }
                .controlSize(.small)

                Button("Refresh") {
                    modelDownloadManager.refreshModelStates()
                    runtimeModel.refreshAvailableModels()
                }
                .controlSize(.small)
            }
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

    private func downloadButtonTitle(for state: ModelDownloadState) -> String {
        switch state {
        case .idle:
            return "Download"
        case .downloading:
            return "Downloading"
        case .downloaded:
            return "Installed"
        case .failed:
            return "Retry"
        }
    }

    private func isDownloadButtonDisabled(for state: ModelDownloadState) -> Bool {
        switch state {
        case .downloading, .downloaded:
            return true
        case .idle, .failed:
            return false
        }
    }

    private func modelDownloadStatusColor(for state: ModelDownloadState) -> Color {
        switch state {
        case .downloaded:
            return .green
        case .downloading:
            return .blue
        case .failed:
            return .red
        case .idle:
            return .secondary
        }
    }
}

struct MenuBarSuggestionControlsSection: View {
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SuggestionWordCountPickerRow(
                title: "Words",
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

struct MenuBarStatusSection: View {
    let presentation: MenuBarPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(presentation.statusRows) { row in
                CompactStatusRow(
                    title: row.title,
                    value: row.value,
                    tone: row.tone.color
                )
            }
        }
    }
}

struct MenuBarDebugSection: View {
    let previews: [MenuBarDebugPreview]

    var body: some View {
        ForEach(previews) { preview in
            DebugPreviewCard(title: preview.title, text: preview.text)
        }
    }
}

struct MenuBarActionsRow: View {
    let welcomeCoordinator: WelcomeCoordinator

    var body: some View {
        HStack(spacing: 8) {
            Button("Show Welcome") {
                welcomeCoordinator.showWelcome()
            }
            .controlSize(.small)

            Button("Guide") {
                welcomeCoordinator.showGuide()
            }
            .controlSize(.small)

            Spacer(minLength: 0)

            Button("Quit Tabby") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .controlSize(.small)
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let granted: Bool
    let missingLabel: String

    init(title: String, granted: Bool, missingLabel: String = "Required") {
        self.title = title
        self.granted = granted
        self.missingLabel = missingLabel
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 7, height: 7)

            Text("\(title): \(granted ? "Granted" : missingLabel)")
                .font(.caption)
                .foregroundStyle(granted ? Color.primary : Color.red)
                .lineLimit(1)
        }
    }
}

private struct CompactStatusRow: View {
    let title: String
    let value: String
    let tone: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 74, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(tone)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }
}

private struct ModelPickerRow: View {
    let title: String
    let selection: Binding<String>
    let models: [RuntimeModelOption]
    let isDisabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 74, alignment: .leading)

            Picker(title, selection: selection) {
                ForEach(models) { model in
                    Text(model.displayName)
                        .tag(model.filename)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(isDisabled)

            Spacer(minLength: 0)
        }
    }
}

private struct SuggestionWordCountPickerRow: View {
    let title: String
    let selection: Binding<SuggestionWordCountPreset>
    let options: [SuggestionWordCountPreset]

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 74, alignment: .leading)

            Picker(title, selection: selection) {
                ForEach(options) { preset in
                    Text(preset.displayLabel)
                        .tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Spacer(minLength: 0)
        }
    }
}

private struct SuggestionPromptModePickerRow: View {
    let title: String
    let selection: Binding<SuggestionPromptMode>
    let options: [SuggestionPromptMode]

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 74, alignment: .leading)

            Picker(title, selection: selection) {
                ForEach(options) { mode in
                    Text(mode.displayLabel)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Spacer(minLength: 0)
        }
    }
}

private struct DebugPreviewCard: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(5)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
