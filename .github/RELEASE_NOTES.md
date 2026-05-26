# WhisperShortcut 7.29

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Cancellation no longer looks like a crash

- **Cancelling a prompt, transcription, or read-aloud is now silent.** Previously, stopping an in-flight request mid-network-call could surface a "Prompt Error: cancelled" popup with a "Contact Support" button — even though the user just pressed stop. The app now recognises user-initiated cancellation in all its forms (Swift task cancellation, `URLError(.cancelled)`, and the bridged `NSURLErrorCancelled` from URLSession) and quietly returns to the idle state instead of showing an error.

## Full changelog

[Compare v7.28…v7.29](https://github.com/mgsgde/whisper-shortcut/compare/v7.28...v7.29)
