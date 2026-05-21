# WhisperShortcut 7.24

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Chat & Dictate Prompt

- **Pro models now actually think.** Gemini Pro chat models (Gemini 2.5 Pro, Gemini 3 Pro, Gemini 3.1 Pro) run with dynamic reasoning enabled — answers are noticeably stronger at the cost of a few seconds before the first streamed token. Flash models keep instant streaming as before.
- **Refreshed default model lineup.** OpenAI chat defaults to GPT-5.5 and Grok defaults to Grok 4.3 — bringing both providers in line with their current flagship models.
- **Bare `/gemini`, `/grok`, `/openai` commands** in chat now consistently use the same defaults the chat tab uses, so picking a provider without a model gives the same result everywhere.

### Transcription

- **Smarter Gemini transcription requests.** Thinking is now explicitly disabled for transcription, which doesn't benefit from reasoning. Same speed today, but protects against extra latency and cost as Google's models evolve.

### Misc

- **Launch at Login is on by default** for new installs, so WhisperShortcut is ready right after you boot.

## Full changelog

[Compare v7.23…v7.24](https://github.com/mgsgde/whisper-shortcut/compare/v7.23...v7.24)
