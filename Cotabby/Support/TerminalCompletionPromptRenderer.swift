import Foundation

/// File overview:
/// Renders base-model prompts for the two terminal input sources: the shell prompt
/// (`TerminalShellInput`, fed by the shell-integration hooks) and the Claude Code TUI
/// (`ClaudeCodeTuiInput`, fed by the OCR reader).
///
/// Why a separate renderer: `BaseCompletionPromptRenderer` conditions a base model with prose
/// authorship framing ("Written by …", "Writing style: …"). For a shell command line that framing
/// actively hurts — a 2B base model reads "git ch" after a prose preface and continues it as
/// English ("g" → "reeting: hello…", observed in llm-io.jsonl). A base model continues whatever
/// document it believes it is in, so the fix is to make the prompt look like the right kind of
/// document: a terminal transcript for shell input, an assistant-chat draft for the Claude box.
///
/// Like `BaseCompletionPromptRenderer`, the caret prefix is the FINAL bytes of the prompt with
/// trailing whitespace trimmed, so generation begins exactly where the user stopped typing.
enum TerminalCompletionPromptRenderer {
    /// Role strings stamped by `TerminalFocusAdapter` / `TuiFocusAdapter`. Centralized here so the
    /// request factory and tests share one definition instead of re-typing string literals.
    static let shellRole = "TerminalShellInput"
    static let claudeCodeTuiRole = "ClaudeCodeTuiInput"

    static func isTerminalRole(_ role: String) -> Bool {
        role == shellRole || role == claudeCodeTuiRole
    }

    static func prompt(prefixText: String, role: String, subrole: String?) -> String {
        let trimmedPrefix = BaseCompletionPromptRenderer.trimmingTrailingWhitespace(prefixText)
        if role == claudeCodeTuiRole {
            return claudeCodePrompt(trimmedPrefix: trimmedPrefix)
        }
        return shellPrompt(trimmedPrefix: trimmedPrefix, shellName: subrole)
    }

    /// A few-shot fake transcript. Each "$ " line is a complete, ordinary command; the user's
    /// partial command is the last line, unterminated, so the model's most likely continuation is
    /// the rest of a shell command. The examples are deliberately generic (cd / ls / git status)
    /// to bias *form* (this is a command line) without biasing *content* toward any one tool.
    /// Single-line normalization upstream discards anything past the first newline, so the model
    /// inventing further "$ " lines is harmless.
    private static func shellPrompt(trimmedPrefix: String, shellName: String?) -> String {
        let shell = (shellName?.isEmpty == false) ? shellName! : "shell"
        return """
        Transcript of a \(shell) session on macOS. Every line is a complete shell command.
        $ cd ~/projects
        $ ls -la
        $ git status
        $ \(trimmedPrefix)
        """
    }

    /// The Claude Code input box holds natural-language requests to a coding assistant, not shell
    /// commands. Frame the document accordingly and let the model continue the user's sentence.
    private static func claudeCodePrompt(trimmedPrefix: String) -> String {
        """
        A developer is typing a request to an AI coding assistant. The message so far:

        \(trimmedPrefix)
        """
    }
}
