# WhisperShortcut 7.12

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Added

- **OpenAI as a first-class provider**: Add your OpenAI API key in **Settings → General** and pick OpenAI models for transcription, chat, and Dictate Prompt, the same way Gemini and Grok already work.
  - **Transcription**: `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` in the Dictate model picker.
  - **Chat**: `gpt-5`, `gpt-5-mini`, and `gpt-4o-audio-preview` in the chat model picker, with full function calling for Calendar, Tasks, Gmail, and Trello.
  - **Dictate Prompt**: `gpt-4o-audio-preview` accepts the recording directly via inline audio — no transcription detour — exactly like Gemini does today. The Dictation system prompt, screenshot context, and clipboard text are all forwarded.
  - New `/openai` slash command in chat switches the active model to GPT-5, matching `/gemini` and `/grok`.
- **Self-documentation in chat**: Two local chat tools (`list_whisper_shortcut_docs` and `read_whisper_shortcut_doc`) ground the model in the app's actual bundled README and data-directories docs. Asking the chat "how does WhisperShortcut work?", "where are my recordings stored?", or "what does the Dictate Prompt setting do?" now returns answers based on the real documentation instead of guesses.

### Changed

- **"Custom Transcription API" → "Self-hosted Transcription Endpoint"**: The previously misleading "Custom" entry is reframed for users running their own OpenAI-compatible servers (faster-whisper-server, Cloudflare-fronted Whisper, etc.). Its configuration UI moves out of General settings and now appears under the Dictate model picker, only when the entry is selected. Persisted settings continue to resolve — no migration needed.
- **Whisper Glossary and language forwarded to custom transcription endpoints**: When dictation is routed through OpenAI's hosted endpoint or your self-hosted endpoint, your Whisper Glossary is sent as the `prompt` bias hint and your language selection as the `language` parameter. The Dictation system prompt does not apply to OpenAI's transcription endpoint (it has no equivalent field).

### Fixed

- **Misleading server-error message**: The "An error occurred on Google's servers" notification now reads "The AI provider returned an error" — it correctly covers Gemini, xAI, OpenAI, and self-hosted endpoints.
- **OpenAI Dictate Prompt screenshot crash**: `gpt-4o-audio-preview` is audio-only and rejected screenshots with HTTP 400. The screenshot is now skipped automatically when the selected model can't accept images.

## Full changelog

[Compare v7.11…v7.12](https://github.com/mgsgde/whisper-shortcut/compare/v7.11...v7.12)
