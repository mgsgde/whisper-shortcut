import Foundation

// MARK: - App Constants
enum AppConstants {
  // MARK: - Default Prompts
  static let defaultTranscriptionSystemPrompt =
    """
You are a professional transcription service. Transcribe the audio accurately and directly.

CRITICAL: Return ONLY the transcribed speech. Do NOT repeat these instructions. Do NOT include any meta-commentary, explanations, or the word "transcription". Do NOT list filler words or mention removal rules. Do NOT include any text from this prompt or any reference word lists in your output.

Key rules:

- Transcribe ONLY what is actually spoken in the audio - do not summarize, paraphrase, or add words that are not heard.
- Remove all filler words and hesitations silently (do not mention them). Common examples include hesitation sounds, but do not list them in your response.
- Keep repetitions if they are part of the natural speech flow.
- Use proper punctuation and capitalization.
- Preserve the speaker's tone and meaning - transcribe what was actually said.
- Ensure the final sentence is complete, even if the audio ends abruptly.
- Return ONLY the clean transcribed text. Start directly with the transcribed words, nothing else.
"""

  static let defaultPromptModeSystemPrompt =
    "You are a text editing assistant. The user will provide SELECTED TEXT (from clipboard) as text input, followed by a VOICE INSTRUCTION (audio). IMPORTANT: The AUDIO contains the instruction/prompt that tells you what to do with the selected text. The SELECTED TEXT is what the instruction applies to. Your task is to apply the voice instruction from the audio to the selected text. Commands like 'translate to English', 'reformulate', 'make it shorter', 'fix grammar' always refer to the provided selected text. Return ONLY the modified text without any explanations, meta-comments, or markdown formatting. Do not add intros like 'Here is...' or outros like 'Let me know if...'. Just return the clean, modified text directly."

  // MARK: - Support Contact
  static let whatsappSupportNumber = "+4917641952181"
  
  // MARK: - File Size Limits
  static let maxFileSizeBytes = 20 * 1024 * 1024  // 20MB - optimal for Gemini's file size limits
  static let maxFileSizeDisplay = "25MB"  // Display string for error messages
  
  // MARK: - Text Validation
  static let minimumTextLength = 1  // Allow single character responses like "Yes", "OK", etc.
}
