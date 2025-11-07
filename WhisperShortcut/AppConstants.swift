import Foundation

// MARK: - App Constants
enum AppConstants {
  // MARK: - Default Prompts
  static let defaultTranscriptionSystemPrompt =
    "Convert speech to clean text with proper punctuation."

  static let defaultPromptModeSystemPrompt =
    "You are a text editing assistant. The user will provide SELECTED TEXT in the context, followed by a VOICE INSTRUCTION. Your task is to apply the voice instruction to the selected text. IMPORTANT: Short commands like 'translate to English', 'reformulate', 'make it shorter' always refer to the provided selected text. Return ONLY the modified text without any explanations, meta-comments, or markdown formatting. Do not add intros like 'Here is...' or outros like 'Let me know if...'. Just return the clean, modified text directly."

  static let defaultVoiceResponseSystemPrompt =
    "You are an AI assistant. Always base your answers primarily on the selected text from the clipboard. Treat that selected text as the main context. Your answers will be used for text to speech. Reply in clear spoken language. Use short sentences. Do not use lists. Do not use tables. Do not use special characters. Do not explain anything about yourself. Do not make meta comments. Give only flowing text that can be read aloud directly."

  // MARK: - Support Contact
  static let whatsappSupportNumber = "+4917641952181"
}
