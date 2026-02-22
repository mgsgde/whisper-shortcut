# Release v6.1.0

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### New Features

_(None in this release.)_

### Improvements

- **Smart Improvement**: Default model is Gemini 3.1 Pro; Gemini 3 Flash migrated to 3.1 Pro. Runs in background with start popup; running state synced when returning to the tab. Defaults to “Never” when no Gemini credential. Smart Improvement tab in Settings with Data & Reset and consistent button layout. Gemini 3 Pro and 3.1 Pro available for Smart Improvement.
- **Transcription & Dictation**: Default dictation model is Gemini 2.5 Flash-Lite (marked as recommended). Gemini 2.0 Flash deprecated. Whisper auto-detect fixed when language is unset (detectLanguage true). Loading notification when initializing offline transcription model. Clearer error message when a deprecated Gemini model returns 404.
- **TTS**: Refactored to use GeminiTTSRequest structure; aligned with official Gemini docs. System instruction added so transcripts are read literally (fixes TTS 400). Removed unused ttsSystemInstruction; isRecommended fixed for gemini25Flash.
- **Settings**: Terminology unified from “Keyboard Shortcuts” to “Keyboard Shortcut”. Refactored SettingsView and related components; consistent HStack spacing (12) for Open folder buttons. General settings reorganized (state transitions, error presentation). Two-second option for notification display duration. “Available keys” hint in Transcribe Meeting shortcut section. GitHub link in Support & Feedback.
- **Error handling & logging**: ChunkError and typed errors; state transitions and error presentation refactored. Stronger error handling and retry logic in GeminiAPIClient and MenuBarController. Errors written to UserContext/errors-YYYY-MM-DD.log with 30-day retention. Gemini model logged in system prompt and user context history. Code consistency fixes (AppState-only state, low-priority cleanups).
- **Docs & tooling**: Gemini model documentation and skill for model ID lookup. Script to test Gemini generateContent models. Privacy policy updated (paths, English UI, in-app deletion). Package.resolved removed from version control.

### Fixes

- **Gemini without API key**: When Gemini is selected but no API key is set, the app no longer silently falls back to Whisper; behavior is explicit.
- **PromptModelSelectionView**: Removed model-initialization note (not relevant for Gemini).

## Full Changelog

For a complete list of changes, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v6.0.0...v6.1.0).
