import Foundation

/// File overview:
/// Normalizes and formats the optional user-authored "custom AI instructions" block that will
/// eventually come from Settings.
///
/// Why this type exists:
/// user preferences are not the same thing as Tabby's base inline-completion rules. By centralizing
/// formatting here, both llama and Foundation Models can consume the same preference payload
/// without duplicating trimming/section-wrapping logic in multiple renderers.
enum CustomAIInstructionFormatter {
    /// Returns `nil` for empty or whitespace-only values so prompt renderers can omit the section
    /// entirely instead of carrying empty headings into the model context.
    static func normalized(_ instructions: String?) -> String? {
        guard let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    /// Produces a backend-agnostic preference block. Renderers can insert these lines into either
    /// a system-instructions channel or a single prompt string while preserving the same meaning.
    static func promptSectionLines(from instructions: String?) -> [String] {
        guard let normalizedInstructions = normalized(instructions) else {
            return []
        }

        let instructionLines = normalizedInstructions
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }

        return ["Custom AI writing preferences:"] +
            instructionLines +
            [
                "Apply this guidance only when it fits the surrounding text.",
                "Do not mention or explain these preferences."
            ]
    }
}
