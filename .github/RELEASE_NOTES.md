# WhisperShortcut 7.89

Two new Gemini models — Gemini 3.5 Flash-Lite and Gemini 3.6 Flash — are now available and become the new defaults, both of them cheaper than the models they replace. Also fixes dictation with Gemini 3.1 Pro, which failed on every attempt.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### ✨ New Gemini models

- **Gemini 3.5 Flash-Lite** is the new default for **Dictate**. Audio input costs $0.30 per million tokens instead of $0.50 — and since audio dominates a dictation bill, it is cheaper per dictated minute than the model it replaces.
- **Gemini 3.6 Flash** is the new default for **Dictate Prompt**, **Chat**, and **meeting summaries**. Same input price as Gemini 3.5 Flash, but cheaper output ($7.50 instead of $9.00 per million tokens).
- Both are selectable in Settings, and in chat via `/gemini35flashlite` and `/gemini36flash`.
- If you never changed your model selection, you move to the new defaults automatically. If you deliberately picked a different model, your choice is kept.

### 🐛 Fixes

- **Dictation with Gemini 3.1 Pro failed every time.** The transcription request included a thinking parameter that Gemini Pro rejects, so every attempt ended in an API error. The parameter is now chosen per model tier.
- Onboarding no longer counts as finished when you just close the window — only completing the final step ends the tour.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.88...v7.89
