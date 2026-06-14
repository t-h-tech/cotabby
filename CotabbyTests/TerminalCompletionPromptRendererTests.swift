import XCTest
@testable import Cotabby

final class TerminalCompletionPromptRendererTests: XCTestCase {

    // MARK: - Role classification

    func test_isTerminalRole_matchesBothTerminalSources() {
        XCTAssertTrue(TerminalCompletionPromptRenderer.isTerminalRole("TerminalShellInput"))
        XCTAssertTrue(TerminalCompletionPromptRenderer.isTerminalRole("ClaudeCodeTuiInput"))
    }

    func test_isTerminalRole_rejectsAXRoles() {
        XCTAssertFalse(TerminalCompletionPromptRenderer.isTerminalRole("AXTextArea"))
        XCTAssertFalse(TerminalCompletionPromptRenderer.isTerminalRole("AXTextField"))
        XCTAssertFalse(TerminalCompletionPromptRenderer.isTerminalRole(""))
    }

    // MARK: - Shell prompt shape

    func test_shellPrompt_endsWithPrefixAsLastCommandLine() {
        let prompt = TerminalCompletionPromptRenderer.prompt(
            prefixText: "git ch",
            role: "TerminalShellInput",
            subrole: "zsh"
        )
        XCTAssertTrue(prompt.hasSuffix("$ git ch"), "caret prefix must be the final bytes: \(prompt)")
        XCTAssertTrue(prompt.contains("zsh"), "shell name should condition the transcript")
    }

    func test_shellPrompt_trimsTrailingWhitespaceFromPrefix() {
        let prompt = TerminalCompletionPromptRenderer.prompt(
            prefixText: "git checkout ",
            role: "TerminalShellInput",
            subrole: "bash"
        )
        XCTAssertTrue(prompt.hasSuffix("$ git checkout"))
    }

    func test_shellPrompt_unknownShellFallsBackToGenericName() {
        let prompt = TerminalCompletionPromptRenderer.prompt(
            prefixText: "ls",
            role: "TerminalShellInput",
            subrole: nil
        )
        XCTAssertTrue(prompt.contains("shell session"))
        XCTAssertTrue(prompt.hasSuffix("$ ls"))
    }

    func test_shellPrompt_containsNoProsePersonaFraming() {
        let prompt = TerminalCompletionPromptRenderer.prompt(
            prefixText: "git ch",
            role: "TerminalShellInput",
            subrole: "zsh"
        )
        XCTAssertFalse(prompt.contains("Written by"))
        XCTAssertFalse(prompt.contains("Writing style"))
    }

    // MARK: - Claude Code TUI prompt shape

    func test_claudeCodePrompt_endsWithPrefixAndMentionsAssistant() {
        let prompt = TerminalCompletionPromptRenderer.prompt(
            prefixText: "explain this fu",
            role: "ClaudeCodeTuiInput",
            subrole: "OCR"
        )
        XCTAssertTrue(prompt.hasSuffix("explain this fu"))
        XCTAssertTrue(prompt.contains("coding assistant"))
        XCTAssertFalse(prompt.contains("$ "), "TUI input is prose, not a shell transcript")
    }
}
