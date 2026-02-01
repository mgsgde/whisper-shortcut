# Release v5.3.3

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### New Features

- **Prompt Mode Conversation History**: Speech-to-Prompt and Prompt & Read now keep conversation history with the AI. Your previous instructions and the model’s responses are sent in follow-up requests for more coherent, context-aware edits.
- **Transcription History Timeout**: Configurable timeout for fetching transcription history so long-running or stuck requests no longer block the app.

### Improvements

- **Conversation History Handling**: More robust management of conversation history for prompt modes, including clearer state and error handling.
- **Gemini Flash Endpoint**: Transcription updated to use the correct Gemini Flash endpoint for reliability.
- **Audio File Validation**: Refined validation of recorded audio files before processing.
- **TTS Cancellation**: Better cancellation handling and user feedback when stopping Read Aloud or Prompt & Read playback.
- **TTS Processing**: Cleaner TTS logic, improved audio session handling, and more reliable chunk processing.

## Full Changelog

For a complete list of changes, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v5.3.2...v5.3.3).
