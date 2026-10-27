import Foundation

/// Suggestion focus for Smart Improvement (scheduler and ContextDerivation).
enum GenerationKind: Equatable, Codable {
  case dictation
  case whisperGlossary
  case promptMode
  case chat

  /// Display name for the review window title and summary messages.
  var improvementDisplayName: String {
    switch self {
    case .dictation: return String(localized: "Dictation Prompt")
    case .whisperGlossary: return String(localized: "Glossary")
    case .promptMode: return String(localized: "Dictate Prompt System Prompt")
    case .chat: return String(localized: "Chat System Prompt")
    }
  }
}
