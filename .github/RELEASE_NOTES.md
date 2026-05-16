# WhisperShortcut 7.17

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Fixed

- **Dictation silently returning to idle (#28)**: The silence detector introduced earlier could mis-flag real recordings on low-gain microphones, causing the app to jump straight from Recording to Idle with no feedback — most reliably reproduced with Whisper Small (Offline). The gate is now skipped entirely for offline Whisper (no API cost to protect against), so offline transcription always runs.
- **Silent failures now explain themselves**: When a cloud recording is gated as silent, a "No speech detected" popup now appears with a hint to check microphone input, instead of silently returning to idle.

### Improved

- **More forgiving silence threshold**: Lowered from -35 dB to -45 dB so quiet mics and softer voices no longer get mistakenly classified as silence.

## Full changelog

[Compare v7.16…v7.17](https://github.com/mgsgde/whisper-shortcut/compare/v7.16...v7.17)
