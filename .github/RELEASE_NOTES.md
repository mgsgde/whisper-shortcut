**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Offline transcription
- **A missing on-device model now offers the download.** When a local Whisper model failed to *load* because its files were missing or incomplete, the app showed a generic file error. It now recognises this case the same way it already did during transcription and prompts you to download the model again.

## Smart Improvement
- A chat system prompt that contains only whitespace is now treated as empty everywhere, so the Chat focus no longer sees an "empty but present" prompt in one place and nothing in another.

## Under the hood
- Large internal cleanup of Chat, Gemini streaming, Read Aloud and meeting code (refactor run #8): one retry-on-429 loop for Read Aloud requests, one stream-stall watchdog shared by chat and speech streams, one Gemini request builder, and Chat request/error formatting moved out of the chat view model. No intended change in behaviour beyond the two items above; 11 new tests.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.23...v8.24
