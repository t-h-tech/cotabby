import Foundation

/// File overview:
/// Centralizes the repeated gating rules that decide whether Tabby can react to the current focus
/// and whether a refreshed prediction is worthwhile. This is intentionally pure and deterministic.
///
/// The value of this helper is consistency: permission/focus checks appear in several coordinator
/// paths, and moving them here prevents small wording or branching differences from creeping in.
enum SuggestionAvailabilityEvaluator {
    static func disabledReason(
        inputMonitoringGranted: Bool,
        focusSnapshot: FocusSnapshot
    ) -> String? {
        guard inputMonitoringGranted else {
            return "Input Monitoring permission is required before Tabby can react to typing."
        }

        switch focusSnapshot.capability {
        case .supported:
            return nil
        case let .blocked(reason), let .unsupported(reason):
            return reason
        }
    }

    static func shouldSchedulePrediction(
        inputMonitoringGranted: Bool,
        focusSnapshot: FocusSnapshot
    ) -> Bool {
        disabledReason(inputMonitoringGranted: inputMonitoringGranted, focusSnapshot: focusSnapshot) == nil
    }

    static func shouldSchedulePredictionWhenVisualContextBecomesReady(
        focusSnapshot: FocusSnapshot,
        matching elementIdentifier: String
    ) -> Bool {
        guard case .supported = focusSnapshot.capability,
              let context = focusSnapshot.context,
              context.elementIdentifier == elementIdentifier
        else {
            return false
        }

        return SuggestionRequestFactory.shouldGenerateSuggestion(for: context.precedingText)
    }
}
