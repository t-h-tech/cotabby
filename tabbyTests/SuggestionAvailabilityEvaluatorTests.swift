import XCTest
@testable import tabby

/// Tests for the gate every coordinator path runs through before starting a
/// generation. The value of concentrating these checks in one function is
/// precisely that UI copy and the gate logic can't drift; these tests lock
/// that contract in.
final class SuggestionAvailabilityEvaluatorTests: XCTestCase {

    // Build a FocusSnapshot with only the capability varied — none of the gate
    // logic we're testing here touches `context` or `inspection`, so leaving
    // them nil keeps each test focused on the single axis under test.
    private func makeSnapshot(capability: FocusCapability) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "app.test",
            capability: capability,
            context: nil,
            inspection: nil
        )
    }

    // MARK: - disabledReason: exact-string contracts

    /// If this string ever changes, the menu-bar status copy will silently
    /// change alongside it. Pin it so any copy edit is deliberate.
    func test_disabledReason_whenGloballyDisabled_returnsFixedCopy() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Tabby is turned off.")
    }

    func test_disabledReason_whenInputMonitoringDenied_mentionsPermission() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: false,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Input Monitoring") ?? false,
                      "reason should point the user at the permission they need to grant")
    }

    // MARK: - disabledReason: guard ordering

    /// Global-off takes precedence over permission-denied. Important because
    /// the copy the user sees should be the thing they most need to know; if
    /// Tabby is off, the Input Monitoring message is a distraction.
    func test_disabledReason_globalDisabled_winsOverInputMonitoringDenied() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            inputMonitoringGranted: false,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Tabby is turned off.")
    }

    // MARK: - disabledReason: capability passthrough

    /// The .blocked and .unsupported cases both surface their own reason
    /// string so the menu can explain which field Tabby is refusing to
    /// handle. Test that the evaluator passes these through verbatim.
    func test_disabledReason_blockedCapability_returnsCapabilityReason() {
        let blockReason = "Secure field — Tabby intentionally won't run here."
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .blocked(blockReason))
        )

        XCTAssertEqual(reason, blockReason)
    }

    func test_disabledReason_unsupportedCapability_returnsCapabilityReason() {
        let unsupportedReason = "No focused text input"
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .unsupported(unsupportedReason))
        )

        XCTAssertEqual(reason, unsupportedReason)
    }

    // MARK: - disabledReason: happy path

    func test_disabledReason_whenEverythingAllowed_returnsNil() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertNil(reason)
    }

    // MARK: - shouldSchedulePrediction (boolean wrapper)

    /// shouldSchedulePrediction is the bool collapse of disabledReason == nil.
    /// Tests both sides of the nil boundary so a future refactor of one
    /// function without the other would trip.
    func test_shouldSchedulePrediction_trueWhenNoDisabledReason() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertTrue(ok)
    }

    func test_shouldSchedulePrediction_falseWhenGloballyDisabled() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: false,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertFalse(ok)
    }

    func test_shouldSchedulePrediction_falseWhenCapabilityUnsupported() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .unsupported("No focused text input"))
        )

        XCTAssertFalse(ok)
    }
}
