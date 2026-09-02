import Foundation

/// One-tap Dictate Prompt verbs so the user does not have to speak "correct" / "format" /
/// "rephrase" through STT (ledger I5). Armed for a single recording, then consumed.
enum DictatePromptPreset: String, CaseIterable {
  case correct
  case format
  case rephrase

  var menuTitle: String {
    switch self {
    case .correct: return "Correct"
    case .format: return "Format"
    case .rephrase: return "Rephrase"
    }
  }

  var instruction: String {
    switch self {
    case .correct:
      return "Correct grammar, spelling, and punctuation of the selected text. Keep the meaning. Output only the corrected text."
    case .format:
      return "Format the selected text for readability (paragraphs, lists, headings) without changing meaning. Output only the formatted text."
    case .rephrase:
      return "Rephrase the selected text for clarity and a natural tone. Keep the meaning. Output only the rephrased text."
    }
  }

  private static let pendingKey = "dictatePromptPresetPending"

  static var pending: DictatePromptPreset? {
    get {
      guard let raw = UserDefaults.standard.string(forKey: pendingKey) else { return nil }
      return DictatePromptPreset(rawValue: raw)
    }
    set {
      if let newValue {
        UserDefaults.standard.set(newValue.rawValue, forKey: pendingKey)
      } else {
        UserDefaults.standard.removeObject(forKey: pendingKey)
      }
    }
  }

  /// Returns the armed instruction and clears it so the next recording is a custom prompt.
  static func consumePendingInstruction() -> String? {
    guard let preset = pending else { return nil }
    pending = nil
    return preset.instruction
  }
}
