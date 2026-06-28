import XCTest
@testable import Cotabby

/// Locks down the reload-focus hotkey's storage contract: it defaults to unbound (opt-in, like the
/// global toggle), persists across model instances, and clears back to the disabled sentinel.
@MainActor
final class ReloadFocusKeybindTests: XCTestCase {

    /// A fresh install has no reload hotkey bound — the feature is opt-in.
    func test_default_isUnbound() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.reloadFocusKeyCode, SuggestionSettingsModel.disabledKeyCode)
        XCTAssertEqual(model.reloadFocusKeyLabel, SuggestionSettingsModel.disabledKeyLabel)
        XCTAssertTrue(model.reloadFocusKeyModifiers.isEmpty)
    }

    /// Setting the hotkey persists to UserDefaults, so a fresh model (same defaults) loads it back.
    func test_setReloadFocusKey_persistsAcrossInstances() {
        let (model, defaults) = makeModel()
        model.setReloadFocusKey(keyCode: 49, modifiers: [.command, .shift], label: "⌘⇧Space")

        XCTAssertEqual(model.reloadFocusKeyCode, 49)
        XCTAssertEqual(model.reloadFocusKeyModifiers, [.command, .shift])
        XCTAssertEqual(model.reloadFocusKeyLabel, "⌘⇧Space")

        let reloaded = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        XCTAssertEqual(reloaded.reloadFocusKeyCode, 49)
        XCTAssertEqual(reloaded.reloadFocusKeyModifiers, [.command, .shift])
        XCTAssertEqual(reloaded.reloadFocusKeyLabel, "⌘⇧Space")
    }

    /// Clearing unbinds the hotkey (disabled sentinel + empty modifiers), and that persists too.
    func test_clearReloadFocusKey_unbinds() {
        let (model, defaults) = makeModel()
        model.setReloadFocusKey(keyCode: 49, modifiers: [.command], label: "⌘Space")
        model.clearReloadFocusKey()

        XCTAssertEqual(model.reloadFocusKeyCode, SuggestionSettingsModel.disabledKeyCode)
        XCTAssertTrue(model.reloadFocusKeyModifiers.isEmpty)

        let reloaded = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        XCTAssertEqual(reloaded.reloadFocusKeyCode, SuggestionSettingsModel.disabledKeyCode)
    }

    private func makeModel() -> (SuggestionSettingsModel, UserDefaults) {
        let suiteName = "cotabby.test.reloadFocusKeybind.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (SuggestionSettingsModel(configuration: .standard, userDefaults: defaults), defaults)
    }
}
