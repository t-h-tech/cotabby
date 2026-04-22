import XCTest
@testable import tabby

/// Tests for the prompt-rendering boundary between DECIDE and GENERATE.
///
/// These are pure-function tests — no mocks, no I/O. The whole point of
/// LlamaPromptRenderer is that given the same inputs, it returns the exact
/// same string, so every assertion here is deterministic.
final class LlamaPromptRendererTests: XCTestCase {

    // MARK: - prefixOnly mode

    /// Fast path must return the prefix verbatim. If this ever breaks, base
    /// models will see unexpected framing tokens and start hallucinating
    /// "Sure," / "Here's" continuations.
    func test_prefixOnly_returnsPrefixVerbatim() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Hello, wor",
            applicationName: "TestApp",
            promptMode: .prefixOnly,
            completionLengthInstruction: "Keep it short.",
            customAIInstructions: nil
        )

        XCTAssertEqual(prompt, "Hello, wor")
    }

    /// prefixOnly deliberately ignores custom instructions — documented as the
    /// "low-overhead path" in the renderer. If these ever leak in, base models
    /// would suddenly see chat framing they don't know how to handle.
    func test_prefixOnly_ignoresCustomInstructions() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "foo",
            applicationName: "TestApp",
            promptMode: .prefixOnly,
            completionLengthInstruction: "Short.",
            customAIInstructions: "UNIQUE_MARKER_SHOULD_NOT_APPEAR"
        )

        XCTAssertEqual(prompt, "foo")
        XCTAssertFalse(prompt.contains("UNIQUE_MARKER_SHOULD_NOT_APPEAR"))
    }

    // MARK: - guided mode

    /// The structural contract of guided mode: three labelled sections the
    /// instruct model is trained to parse. Losing any of them would silently
    /// degrade output quality without throwing.
    func test_guided_containsTaskAndOutputContract() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Once upon",
            applicationName: "Messages",
            promptMode: .guided,
            completionLengthInstruction: "Keep completion short.",
            customAIInstructions: nil
        )

        XCTAssertTrue(prompt.contains("Task:"), "guided prompt should include Task section")
        XCTAssertTrue(prompt.contains("Output contract:"), "guided prompt should include Output contract section")
        XCTAssertTrue(prompt.contains("Context:"), "guided prompt should include Context section")
    }

    func test_guided_includesApplicationNameAndPrefix() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "My prefix text here",
            applicationName: "Slack",
            promptMode: .guided,
            completionLengthInstruction: "Short.",
            customAIInstructions: nil
        )

        XCTAssertTrue(prompt.contains("App: Slack"))
        XCTAssertTrue(prompt.contains("My prefix text here"))
    }

    /// The completion-length instruction is chosen from the user's word-count
    /// preset. It must reach the prompt verbatim so the model sees the exact
    /// guidance the UI showed the user.
    func test_guided_includesCompletionLengthInstruction() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "x",
            applicationName: "App",
            promptMode: .guided,
            completionLengthInstruction: "UNIQUE_LENGTH_MARKER_7_TO_12_WORDS",
            customAIInstructions: nil
        )

        XCTAssertTrue(prompt.contains("UNIQUE_LENGTH_MARKER_7_TO_12_WORDS"))
    }

    func test_guided_includesCustomInstructionsWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "x",
            applicationName: "App",
            promptMode: .guided,
            completionLengthInstruction: "Short.",
            customAIInstructions: "UNIQUE_CUSTOM_MARKER_ZQRT"
        )

        XCTAssertTrue(prompt.contains("UNIQUE_CUSTOM_MARKER_ZQRT"),
                      "guided prompt should carry user-provided custom instructions")
    }

    /// The prefix is always the *last* section of guided mode — the model
    /// continues from the last token, so the prefix has to come last.
    /// Tests the contract that prefix comes after Context:/App:/Text before caret:.
    func test_guided_prefixAppearsAfterContextHeader() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX_BODY_XYZ",
            applicationName: "App",
            promptMode: .guided,
            completionLengthInstruction: "Short.",
            customAIInstructions: nil
        )

        guard let contextRange = prompt.range(of: "Context:"),
              let prefixRange = prompt.range(of: "PREFIX_BODY_XYZ") else {
            XCTFail("Expected both Context: and PREFIX_BODY_XYZ in the prompt")
            return
        }

        XCTAssertLessThan(contextRange.lowerBound, prefixRange.lowerBound,
                          "prefix must appear after the Context: header")
    }
}
