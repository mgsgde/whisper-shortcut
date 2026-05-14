# WhisperShortcut 7.16

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Changed

- **Dictate Prompt default model**: New installs and resets now default to **Gemini 3 Flash** (replacing Flash-Lite) for stronger adherence to nuanced edit instructions.
- **Dictate Prompt behavior**: The system prompt now includes explicit **language preservation** and **minimal-edit** rules so the model keeps the source language unless you clearly ask for translation, and follows “only the correction” style requests instead of rewriting whole documents.

### Improved

- **Chat attachment display**: Assistant-visible context for attachments now includes **name and type** instead of a generic attachment count, so replies can reference what you actually sent.
- **Slash command plumbing**: `/copy` is included in the internally recognized command set, and the prompt that lists available slash commands is simplified for more reliable answers when you ask what commands exist.

### Notes

- **Grok / xAI**: Comment-only clarification around 429 error string matching (no user-visible behavior change intended).

## Full changelog

[Compare v7.15…v7.16](https://github.com/mgsgde/whisper-shortcut/compare/v7.15...v7.16)
