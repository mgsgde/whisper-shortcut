# WhisperShortcut 7.20

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Fixed

- **Settings no longer feels frozen after downloading an offline Whisper model**: The "download complete" confirmation was a SwiftUI alert that ended up hidden behind the Settings window — invisible, but it blocked interaction. It now appears as the same toast-style popup used elsewhere in the app, which sits above all other windows.
- **Download confirmation stays visible long enough to read**: The popup now shows for 10 seconds (was 1 second) so you have time to read the note about the first transcription taking a moment to initialize the model.

## Full changelog

[Compare v7.19…v7.20](https://github.com/mgsgde/whisper-shortcut/compare/v7.19...v7.20)
