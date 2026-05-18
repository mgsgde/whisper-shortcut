# WhisperShortcut 7.19

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Fixed

- **Better transcription quality for long non-WAV recordings**: When transcribing files larger than 20 MB that weren't WAV (e.g. mp3, m4a, flac), WhisperShortcut was telling Gemini the upload was a WAV file. The original audio format is now passed through correctly, which can improve accuracy on those uploads.
- **No more wasted API calls after Dictate Prompt finishes**: A background voice-to-text request that records what you said for the conversation history now stops cleanly when it times out, instead of continuing to run (and consume quota) after the response was already returned to you.
- **Clearer error message for OpenAI API key problems**: The "Authentication Error" message used to mention "Google API key" even when the failure came from OpenAI. The message is now provider-neutral.

### Internal

- ~70 lines of duplicated request scaffolding removed from `SpeechService` (shared Gemini Dictate Prompt helpers, retry helper, dead constants). No user-visible behavior change beyond the items above.

## Full changelog

[Compare v7.18…v7.19](https://github.com/mgsgde/whisper-shortcut/compare/v7.18...v7.19)
