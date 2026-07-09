# WhisperShortcut 7.83

Streaming dictate reliability and a cleaner recording UI.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 🎙️ Streaming dictate fix

- **Long recordings no longer freeze**: When a streaming dictate session captured more than 45 seconds of speech without a silence break, the in-flight chunk was split internally — and that background work accidentally drove the global progress UI, pulling the app state out of recording and leaving transcription stuck. Background streaming chunks now transcribe silently without hijacking the state machine.

### 🎨 Recording UI

- **Compact processing pill**: The bottom-center recording indicator shrinks to a compact size while your audio is being transcribed, so it stays out of the way.
- **No duplicate popups**: Chunk-processing popups are suppressed when the recording pill is already visible — one clear progress indicator instead of overlapping notifications.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.82...v7.83
