import Foundation

/// Suggestion focus for Smart Improvement (scheduler and ContextDerivation).
enum GenerationKind: Equatable, Codable {
  case dictation
  case whisperGlossary
  case promptMode
  case geminiChat

  /// Display name for the review window title and summary messages.
  var improvementDisplayName: String {
    switch self {
    case .dictation: return "Dictation Prompt"
    case .whisperGlossary: return "Whisper Glossary"
    case .promptMode: return "Dictate Prompt System Prompt"
    case .geminiChat: return "Chat System Prompt"
    }
  }
}
