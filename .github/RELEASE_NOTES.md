# WhisperShortcut 6.8

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

- **Gemini Chat — streaming and model behavior**: Replies stream incrementally over SSE; generation config, safety settings, and URL context are wired through; Flash tool configuration is corrected and thinking is tuned for smoother streaming. The live stream is parsed more reliably (JSON object depth), and function-call follow-ups preserve `thoughtSignature` where required.
- **Gemini Chat — conversation and tools**: The full chat history is sent to the model; automatic rolling-memory `/remember` flows and related code are removed. **Function calling** adds tools for **clipboard** and **open URL**. Grounding source and support counts are logged per stream for easier debugging.
- **Gemini window and screenshots**: Opening the chat from a shortcut tracks pasteboard changes via `changeCount` so pasted context stays in sync. Chat screenshots **exclude Whisper Shortcut’s own Gemini window** so captures focus on other apps.

## Full changelog

[Compare v6.7.3…v6.8](https://github.com/mgsgde/whisper-shortcut/compare/v6.7.3...v6.8)
