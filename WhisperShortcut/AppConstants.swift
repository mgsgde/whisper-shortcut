import Foundation

// MARK: - App Constants
enum AppConstants {
  // MARK: - Default Prompts
  static let defaultTranscriptionSystemPrompt =
    "Please transcribe this audio accurately, but remove filler words and disfluencies. Keep only the intended meaning. Numbers should be written as digits, not words. Preserve correct punctuation and grammar."

  static let defaultPromptModeSystemPrompt =
    "By default: interpret any prompt as an instruction to adjust the selected text (e.g., rewrite, shorten, improve, translate, correct, or add details). For example:\n\t•\t\"Improve the wording\" → return the improved version.\n\t•\t\"Translate to English\" → return the translation.\n\t•\t\"The place is wrong, correct it\" → return the corrected version.\n\nOnly if an entirely different task is explicitly described, perform that instead. Always return only the adjusted text, without introductions, explanations, metadata, or additional text."

  static let defaultVoiceResponseSystemPrompt =
    "You are an AI assistant. Your answers will be used for text to speech. Always reply in clear spoken language. Use short sentences. No lists. No tables. No special characters. No explanations about yourself. No meta comments. Give only the flowing text that can be read aloud directly."
}
