# WhisperShortcut 7.79

Performance release: dictation results arrive dramatically faster.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### ⚡ Dictation is dramatically faster

- **Streaming transcription**: Long dictations are now transcribed *while you speak*. The recorder splits your dictation at natural pauses and transcribes each part in the background — when you press Stop, only the last few seconds remain to process. A 40-second dictation now delivers its transcript in under 2 seconds, the same wait as a short one. Works with Gemini, OpenAI, and Grok models; offline Whisper and self-hosted endpoints keep the classic path. If anything goes wrong mid-stream, the app automatically falls back to transcribing the whole recording in one call — you never get a partial result.
- **Faster uploads**: Recordings are compressed (AAC) before upload — about 10× smaller, which especially helps on slower connections.
- **Connection pre-warming**: The secure connection to your AI provider is established the moment you start recording, instead of adding delay after you stop.

### 🎙️ New recording indicator

A floating pill at the bottom of the screen shows live microphone level bars while you dictate, with buttons to confirm (✓) or discard (✕) the recording. Recording, processing, and success feedback is now unified at the bottom-center of the screen.

### 📖 Instant glossary learning

When you correct a term by typing it in the chat, WhisperShortcut now notices: capitalized words in typed messages are matched against your recent transcriptions, and consistent human corrections of machine misspellings are added to your dictation glossary instantly. You can also simply tell the chat assistant to remember a spelling.

### Other changes

- New "Rate WhisperShortcut" menu item.
- License changed from CC BY-NC 4.0 to AGPL-3.0.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.78...v7.79
