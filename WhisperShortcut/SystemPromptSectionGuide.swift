import Foundation

/// Purpose and warnings an AI app sees for each system-prompt section.
///
/// English on purpose: this text is read by a model, not shown as app UI. Pure: no file and no
/// settings. Warnings never block a tool call; they tell the model what to fix first.
enum SystemPromptSectionGuide {

  static func purpose(for section: SystemPromptSection) -> String {
    switch section {
    case .dictationAdditions:
      return "Additions to the built-in transcription instructions (Dictate: speech becomes text, verbatim, cleaned of fillers). Belongs here: who the user is, their field, spelling and formatting preferences. Single terms go to whisper_glossary. Ignored by GPT Transcribe and offline models, which use only the glossary."
    case .promptModeAdditions:
      return "Additions to the built-in Dictate Prompt instructions. With text selected, the user speaks an instruction applied to it ('rephrase', 'shorter', 'translate'); with nothing selected, the spoken words become finished text. Belongs here: role and context, tone per app, list style, how composed text should look. A different output format for a specific job (a report layout) belongs in a Template."
    case .dictation:
      return "Legacy full prompt for Dictation. When this text is non-empty it replaces the built-in transcription instructions, so later improvements to those instructions do not apply. Prefer Dictation Additions for context, vocabulary and style."
    case .promptMode:
      return "Legacy full prompt for Dictate Prompt. When this text is non-empty it replaces the built-in instructions. Prefer Dictate Prompt Additions for role, context and style, and a Template for a job-specific output format."
    case .whisperGlossary:
      return "Names and terms the recognizer should spell as the user writes them. One term per line, optionally Term (not \"wrong\"). Offline models and GPT Transcribe use only this list."
    case .chat:
      return "System prompt for the in-app AI Chat. It shapes how chat replies. It does not change Dictation or Dictate Prompt."
    case .readAloudRewrite:
      return "Instructions for rewriting text before Read Aloud speaks it, so the spoken version is natural prose without markdown or symbols."
    }
  }

  /// Warnings for `text`, at most one of each kind, in a fixed order.
  /// `legacyActive` adds the full-replacement warning. The role, task, selected-text and length
  /// checks apply to additions text (the Dictation and Dictate Prompt additions sections).
  static func warnings(for section: SystemPromptSection, text: String, legacyActive: Bool) -> [String] {
    var result: [String] = []
    if legacyActive {
      result.append(
        "A full custom prompt replaces the built-in instructions for this mode, so improvements to them do not reach it. Convert it: keep only context, vocabulary and style as additions.")
    }
    let checksAdditions = section == .dictationAdditions || section == .promptModeAdditions
    guard checksAdditions else { return result }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let head = String(trimmed.prefix(80)).lowercased()
    let folded = trimmed.lowercased()
    let rolePrefixes = ["you are", "du bist", "sie sind", "act as", "ihr seid"]
    if rolePrefixes.contains(where: { head.hasPrefix($0) }) {
      result.append(
        "Starts like a whole prompt. The built-in instructions already set the role and task; keep only context, vocabulary and style.")
    }
    let taskPhrases = [
      "your task", "deine aufgabe", "your only job",
      "ignore the selected", "ignore the user", "ignore previous",
      "ignoriere den markierten", "ignoriere die anweisung", "ignoriere vorherige",
    ]
    if taskPhrases.contains(where: { folded.contains($0) }) {
      result.append(
        "Redefines the task. Additions cannot change the task; keep only context, vocabulary and style.")
    }
    if section == .dictationAdditions {
      let editPhrases = ["selected text", "markierten text", "ausgewählten text", "markierte text"]
      if editPhrases.contains(where: { folded.contains($0) }) {
        result.append(
          "Describes editing selected text, which is Dictate Prompt; move it to dictate_prompt.")
      }
    }
    if trimmed.count > 2_000 {
      result.append(
        "Long additions water down the built-in rules; keep only the few rules the user needs.")
    }
    return result
  }
}
