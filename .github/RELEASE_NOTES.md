# WhisperShortcut 7.13

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Added

- **Web Search for GPT-5 and GPT-5 Mini in chat**: OpenAI chat models now ground responses via OpenAI's hosted Web Search tool, matching how Gemini and Grok do it. Toggle it from the chat composer the same way as for the other providers.
- **OpenAI Dictate Prompt remembers previous turns**: Voice instructions sent to `gpt-4o-audio-preview` now include the recent Dictate Prompt history, so follow-ups like "make it shorter" or "now in French" work the way they do with Gemini. Each instruction is also transcribed for the history view and for Smart Improvement.

### Changed

- **`⌘ + 1`-style shortcuts in the chat empty state**: The on-screen legend in an empty chat session now reads `⌘ + 1 Speech-to-Text` instead of the compact `⌘1`, so it's clearer that the modifier and the key are pressed together. The menu bar continues to use the native macOS glyph form.
- **`/openai` defaults to GPT-5 Mini**: Typing `/openai` with no model argument now switches the chat to GPT-5 Mini — cheaper and faster as a baseline. You can still get the full model with `/openai gpt-5` or `/model gpt-5`.
- **Transcription model names match chat model names**: Settings → Dictate now lists `GPT-4o Transcribe` and `GPT-4o Mini Transcribe` (dropping the redundant "OpenAI" prefix), consistent with the chat picker.
- **Speech-to-Text settings spell out which backends use which prompt**: The "System prompt" and "Whisper Glossary" sections now state explicitly which transcription backends consume them — Gemini consumes the system prompt; offline Whisper and OpenAI Transcribe consume the glossary.

### Fixed

- **OpenAI chat asked for the wrong API key**: Selecting a GPT-5 model with no Gemini key showed "Add your Google API key…" instead of asking for an OpenAI key. The chat now checks the right credential per provider.
- **`/model gpt 3` no longer routes to Gemini 3**: The fuzzy `/model` matcher now recognizes "openai", "gpt", and "4o" before falling back to generic version-number parsing, and supports a "mini" qualifier (so `/model gpt 5 mini` lands on GPT-5 Mini).
- **OpenAI rate limits no longer surface as generic errors**: HTTP 429 from OpenAI Chat Completions is now treated as a rate-limit (same as Gemini), and the Dictate Prompt path retries briefly instead of failing immediately. Large embedded error payloads are also truncated before being shown.
- **Parallel tool calls in OpenAI chat no longer mis-order**: When the model emits ≥10 parallel tool calls in a single turn, they are now sorted numerically (`2, 10`) instead of lexicographically (`10, 2`).
- **OpenAI Dictate Prompt with oversized audio now fails clearly**: Audio above 20 MB is rejected up front with a clear message instead of timing out partway through the upload (OpenAI's Chat Completions has no Files-API fallback like Gemini does).

## Full changelog

[Compare v7.12…v7.13](https://github.com/mgsgde/whisper-shortcut/compare/v7.12...v7.13)
