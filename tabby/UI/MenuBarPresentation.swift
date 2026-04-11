import Foundation
import SwiftUI

/// File overview:
/// Converts observable app state into small presentation values that the menu bar sections can
/// render directly. This is the menu bar's formatting layer: it shapes text, tones, and previews
/// without owning side effects or view layout.

/// Semantic color roles for menu status UI. Using a small enum instead of raw `Color` values keeps
/// formatting logic easy to test and prevents the formatting layer from mixing in SwiftUI styling
/// decisions beyond tone selection.
enum MenuBarTone: Equatable {
    case primary
    case secondary
    case green
    case blue
    case orange
    case red

    var color: Color {
        switch self {
        case .primary:
            return .primary
        case .secondary:
            return .secondary
        case .green:
            return .green
        case .blue:
            return .blue
        case .orange:
            return .orange
        case .red:
            return .red
        }
    }
}

struct MenuBarHeaderPresentation: Equatable {
    let iconSymbolName: String
    let inputStatusText: String
    let acceptedWordCount: Int
    let tone: MenuBarTone
}

struct MenuBarStatusPresentation: Equatable, Identifiable {
    let title: String
    let value: String
    let tone: MenuBarTone

    var id: String { title }
}

struct MenuBarDebugPreview: Equatable, Identifiable {
    let id: String
    let title: String
    let text: String
}

struct MenuBarPresentation: Equatable {
    let header: MenuBarHeaderPresentation
    let statusRows: [MenuBarStatusPresentation]
    let debugPreviews: [MenuBarDebugPreview]

    static func make(
        runtimeModel: RuntimeBootstrapModel,
        focusModel: FocusTrackingModel,
        suggestionCoordinator: SuggestionCoordinator
    ) -> MenuBarPresentation {
        MenuBarPresentation(
            header: MenuBarHeaderPresentation(
                iconSymbolName: focusModel.menuBarSymbolName,
                inputStatusText: focusModel.menuBarStatusText,
                acceptedWordCount: suggestionCoordinator.totalTabAcceptedWordCount,
                tone: focusTone(for: focusModel.snapshot.capability)
            ),
            statusRows: statusRows(
                runtimeModel: runtimeModel,
                focusModel: focusModel,
                suggestionCoordinator: suggestionCoordinator
            ),
            debugPreviews: debugPreviews(for: suggestionCoordinator)
        )
    }

    private static func statusRows(
        runtimeModel: RuntimeBootstrapModel,
        focusModel: FocusTrackingModel,
        suggestionCoordinator: SuggestionCoordinator
    ) -> [MenuBarStatusPresentation] {
        var rows = [
            MenuBarStatusPresentation(
                title: "Runtime",
                value: runtimeSummaryText(for: runtimeModel),
                tone: runtimeTone(for: runtimeModel.state)
            ),
            MenuBarStatusPresentation(
                title: "Focus",
                value: focusSummaryText(for: focusModel.snapshot),
                tone: focusTone(for: focusModel.snapshot.capability)
            ),
            MenuBarStatusPresentation(
                title: "Suggestion",
                value: suggestionSummaryText(for: suggestionCoordinator),
                tone: suggestionTone(for: suggestionCoordinator.state)
            ),
            MenuBarStatusPresentation(
                title: "Context",
                value: visualContextSummaryText(for: suggestionCoordinator),
                tone: visualContextTone(for: suggestionCoordinator.visualContextStatus)
            )
        ]

        if let acceptanceSummary = acceptanceSummary(for: suggestionCoordinator) {
            rows.append(
                MenuBarStatusPresentation(
                    title: "Accept",
                    value: acceptanceSummary,
                    tone: .secondary
                )
            )
        }

        return rows
    }

    private static func debugPreviews(for suggestionCoordinator: SuggestionCoordinator) -> [MenuBarDebugPreview] {
        var previews: [MenuBarDebugPreview] = []

        if case .generating = suggestionCoordinator.state,
           let prompt = suggestionCoordinator.latestPromptPreview,
           !prompt.isEmpty
        {
            previews.append(MenuBarDebugPreview(id: "prompt", title: "Prompt", text: prompt))
        }

        if case .ready = suggestionCoordinator.state,
           let fullSuggestion = suggestionCoordinator.latestFullSuggestionPreview,
           !fullSuggestion.isEmpty
        {
            let remainingSuggestion = suggestionCoordinator.latestRemainingSuggestionPreview
                ?? suggestionCoordinator.latestSuggestionPreview
            if remainingSuggestion != fullSuggestion {
                previews.append(MenuBarDebugPreview(id: "full-suggestion", title: "Full Suggestion", text: fullSuggestion))
            }
        }

        if suggestionCoordinator.visualContextStatus == .ready,
           let injectedContextSummary = suggestionCoordinator.latestInjectedContextSummary,
           !injectedContextSummary.isEmpty
        {
            previews.append(MenuBarDebugPreview(id: "injected-context", title: "Injected Context", text: injectedContextSummary))
        }

        if let outputPreview = outputPreview(for: suggestionCoordinator) {
            previews.append(
                MenuBarDebugPreview(
                    id: "output",
                    title: outputPreview.title,
                    text: outputPreview.text
                )
            )
        }

        return previews
    }

    private static func outputPreview(for suggestionCoordinator: SuggestionCoordinator) -> (title: String, text: String)? {
        switch suggestionCoordinator.state {
        case .ready:
            if let text = suggestionCoordinator.latestRemainingSuggestionPreview ?? suggestionCoordinator.latestSuggestionPreview {
                return ("Remaining Tail", text)
            }
            return nil

        case .failed:
            if let text = suggestionCoordinator.latestRawModelOutput {
                return ("Last Output", text)
            }
            return nil

        case .idle where suggestionCoordinator.latestStageMessage.localizedCaseInsensitiveContains("empty"):
            let text = suggestionCoordinator.latestRawModelOutput ?? suggestionCoordinator.latestSuggestionPreview
            return text.map { ("Last Output", $0) }

        default:
            return nil
        }
    }

    private static func runtimeSummaryText(for runtimeModel: RuntimeBootstrapModel) -> String {
        let modelName = runtimeModel.selectedModelFilename
            ?? runtimeModel.diagnostics.modelFilePath.map { URL(fileURLWithPath: $0).lastPathComponent }

        switch runtimeModel.state {
        case .ready:
            return [modelName, "Ready"].compactMap { $0 }.joined(separator: " · ")

        case .starting:
            return modelName.map { "\($0) · Starting" } ?? "Starting runtime"

        case .loading:
            return modelName.map { "\($0) · Loading" } ?? "Loading model"

        case .failed(let message):
            return modelName.map { "\($0) · \(message)" } ?? message

        case .idle:
            return modelName.map { "\($0) · Idle" } ?? "Idle"
        }
    }

    private static func focusSummaryText(for snapshot: FocusSnapshot) -> String {
        switch snapshot.capability {
        case .supported:
            return "\(snapshot.applicationName) · Supported"
        case let .blocked(reason), let .unsupported(reason):
            return "\(snapshot.applicationName) · \(reason)"
        }
    }

    private static func suggestionSummaryText(for suggestionCoordinator: SuggestionCoordinator) -> String {
        switch suggestionCoordinator.state {
        case .idle:
            return "No active suggestion"

        case let .disabled(reason), let .failed(reason):
            return reason

        case .debouncing:
            return "Waiting for typing to settle"

        case .generating:
            return "Generating"

        case .ready:
            let accepted = suggestionCoordinator.latestAcceptedCharacterCount ?? 0
            let remaining = suggestionCoordinator.latestRemainingCharacterCount ?? 0
            return "Ready · \(accepted) accepted · \(remaining) remaining"
        }
    }

    private static func visualContextSummaryText(for suggestionCoordinator: SuggestionCoordinator) -> String {
        switch suggestionCoordinator.visualContextStatus {
        case .idle:
            return "Waiting for a supported input"
        case .capturing:
            return "Capturing the frontmost window"
        case .extractingText:
            return "Extracting visible text"
        case .generatingSummary:
            return "Summarizing screenshot context"
        case .ready:
            return suggestionCoordinator.latestInjectedContextSummary ?? "Ready"
        case let .unavailable(reason), let .failed(reason):
            return reason
        }
    }

    private static func acceptanceSummary(for suggestionCoordinator: SuggestionCoordinator) -> String? {
        if case .ready = suggestionCoordinator.state {
            return suggestionCoordinator.latestAcceptanceAction
        }

        guard let latestAcceptanceAction = suggestionCoordinator.latestAcceptanceAction,
              !latestAcceptanceAction.isEmpty
        else {
            return nil
        }

        let stageMessage = suggestionCoordinator.latestStageMessage
        if stageMessage.localizedCaseInsensitiveContains("accepted")
            || stageMessage.localizedCaseInsensitiveContains("typed")
            || stageMessage.localizedCaseInsensitiveContains("consumed")
        {
            return latestAcceptanceAction
        }

        return nil
    }

    private static func runtimeTone(for state: RuntimeBootstrapState) -> MenuBarTone {
        switch state {
        case .ready:
            return .green
        case .failed:
            return .red
        case .starting, .loading:
            return .orange
        case .idle:
            return .secondary
        }
    }

    private static func focusTone(for capability: FocusCapability) -> MenuBarTone {
        switch capability {
        case .supported:
            return .green
        case .blocked:
            return .orange
        case .unsupported:
            return .red
        }
    }

    private static func suggestionTone(for state: SuggestionDebugState) -> MenuBarTone {
        switch state {
        case .ready:
            return .green
        case .failed:
            return .red
        case .disabled, .debouncing:
            return .orange
        case .generating:
            return .blue
        case .idle:
            return .secondary
        }
    }

    private static func visualContextTone(for status: VisualContextStatus) -> MenuBarTone {
        switch status {
        case .ready:
            return .green
        case .capturing, .extractingText, .generatingSummary:
            return .blue
        case .unavailable:
            return .orange
        case .failed:
            return .red
        case .idle:
            return .secondary
        }
    }
}
