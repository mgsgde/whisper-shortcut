# WhisperShortcut 7.57

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Transcription

- **Faster transcription for long recordings.** Audio splitting and upload now run in parallel: chunks start uploading the instant they're carved out, instead of waiting for the entire file to be split first. Saves several seconds on recordings longer than a couple of minutes; scales with length.

### AI Chat

- **Smoother send on long sessions.** Internal cleanup of the streaming pipeline: fewer redundant UI invalidations per send, shared error/cancel path so partial replies are never lost when a stream ends abruptly.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.56...v7.57
