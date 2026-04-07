import Foundation

/// Suggestion focus for Smart Improvement (scheduler and ContextDerivation).
enum GenerationKind: Equatable, Codable {
  case dictation
  case whisperGlossary
  case promptMode
  case promptAndRead
  case geminiChat

  /// Display name for the review window title and summary messages.
  var improvementDisplayName: String {
    switch self {
    case .dictation: return "Dictation Prompt"
    case .whisperGlossary: return "Whisper Glossary"
    case .promptMode: return "Prompt Mode System Prompt"
    case .promptAndRead: return "Prompt Read Mode System Prompt"
    case .geminiChat: return "Gemini Chat System Prompt"
    }
  }
}
