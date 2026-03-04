# Release v6.5

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Meeting Mode

- **Split Gemini window**: Meeting Mode now uses a split view with a rolling summary and supports auto-open and full-screen for focused meeting transcription.

### Gemini Chat

- **Markdown tables**: Chat responses render Markdown tables as SwiftUI grids with bold formatting.
- **Layout**: Reduced margins, input bar limited to 760pt and centered with content; improved padding and content handling for session titles and separator paragraphs.

### Models & transcription

- **Gemini 3.1 Flash-Lite**: New model option for dictation and prompt mode.
- **Smart Improvement default**: Default model for Smart Improvement changed from Gemini 3.1 Pro to Gemini 3 Flash.
- **Whisper Glossary**: Support for offline conditioning via glossary in local Whisper transcription.
- **Reliability**: Better handling of transcription errors for stale audio URLs, cancellation checks in SpeechService, and model loading checks in LocalSpeechService and SpeechService.

### Settings & behavior

- **Settings window**: New option to close the Settings window when it loses focus.
- **Auto-prompt improvement**: Improved error handling in AutoPromptImprovementScheduler.

### Other

- README and plan file cleanup; Dependabot updates for the website (npm/minimatch).

## Full Changelog

For a complete list of changes, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v6.4.6...v6.5).
