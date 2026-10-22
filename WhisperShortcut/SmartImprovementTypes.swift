import Foundation

/// Suggestion focus for Smart Improvement (scheduler and ContextDerivation).
enum GenerationKind: Equatable, Codable {
  case dictation
  case whisperGlossary
  case promptMode
  case chat

  /// Interaction-log mode that counts as primary evidence for this focus.
  ///
  /// ContextDerivation and the scheduler each had this switch. Chat is stored as
  /// `geminiChat` because every provider's turns share one mode key (`ContextLogger.logChat`).
  var primaryMode: InteractionMode {
    switch self {
    case .dictation, .whisperGlossary: return .transcription
    case .promptMode: return .prompt
    case .chat: return .chat
    }
  }

  /// System-prompts section this focus writes. Lived only on the scheduler, so a new focus
  /// could update the mode map and leave the section map behind.
  var systemPromptSection: SystemPromptSection {
    switch self {
    case .dictation: return .dictation
    case .whisperGlossary: return .whisperGlossary
    case .promptMode: return .promptMode
    case .chat: return .chat
    }
  }

  /// Display name for the review window title and summary messages.
  var improvementDisplayName: String {
    switch self {
    case .dictation: return "Dictation Prompt"
    case .whisperGlossary: return "Glossary"
    case .promptMode: return "Dictate Prompt System Prompt"
    case .chat: return "Chat System Prompt"
    }
  }
}
