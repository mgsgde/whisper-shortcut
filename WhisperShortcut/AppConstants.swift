import Foundation

// MARK: - App Constants
enum AppConstants {
  // MARK: - Default Prompts
  static let defaultTranscriptionSystemPrompt =
    "Please transcribe this audio accurately, but remove filler words and disfluencies. Keep only the intended meaning. Numbers should be written as digits, not words. Preserve correct punctuation and grammar."

  static let defaultPromptModeSystemPrompt =
    "By default: interpret any prompt as an instruction to adjust the selected text from clipboard (e.g., rewrite, shorten, improve, translate, correct, or add details). For example:\n\t•\t\"Improve the wording\" → return the improved version.\n\t•\t\"Translate to English\" → return the translation.\n\t•\t\"The place is wrong, correct it\" → return the corrected version.\n\nIf the selected text is part of a list that begins with a dash, always preserve the dash when returning the adjusted version.\n\nOnly if an entirely different task is explicitly described, perform that instead. Always return only the adjusted text, without introductions, explanations, metadata, or additional text."

  static let defaultVoiceResponseSystemPrompt =
    "You are an AI assistant. Always base your answers primarily on the selected text from the clipboard. Treat that selected text as the main context. Your answers will be used for text to speech. Reply in clear spoken language. Use short sentences. Do not use lists. Do not use tables. Do not use special characters. Do not explain anything about yourself. Do not make meta comments. Give only flowing text that can be read aloud directly."

  // MARK: - Support Contact
  static let whatsappSupportNumber = "+4917641952181"
}
