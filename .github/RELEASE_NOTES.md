# WhisperShortcut 7.1

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Chat reliability and model integration

- **Streaming reliability**: Fixed an issue where empty placeholder chat messages could remain after cancellation.
- **Integration hardening**: Improved chat tool argument handling and Google API retry/error behavior for more robust calendar, tasks, and Gmail execution.
- **OAuth stability**: Improved Google auth session lifecycle handling and callback flow to avoid edge-case authorization failures.

### Naming and settings polish

- **Provider-neutral naming**: Continued cleanup from Gemini-prefixed identifiers to Chat/provider-neutral naming.
- **Settings UX**: API key fields are masked by default; chat sidebar defaults are improved for first-run clarity.

### Meeting and rate-limit edge cases

- **Meeting safety**: Renaming meetings now avoids destructive overwrite behavior when target files already exist.
- **Rate-limit coordination**: Waiting logic now better respects extended coordinated backoff windows.

## Full changelog

[Compare v7.0.0…v7.1](https://github.com/mgsgde/whisper-shortcut/compare/v7.0.0...v7.1)
