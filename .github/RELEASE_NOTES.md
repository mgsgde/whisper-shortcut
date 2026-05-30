# WhisperShortcut 7.40

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### 🐛 Fixed a chat freeze on replies with web sources

Chat replies that cite web sources (the `[1] [2]` citation markers from grounded answers) could freeze the app at 100% CPU, requiring a force-quit.

The freeze came from a macOS text-selection edge case: the inline citation links inside selectable reply text put the system into an endless layout loop. Citation markers are now plain text, so the freeze can no longer happen — and you can still open every source from the link chips shown beneath each reply.

Text selection in chat bubbles (both your messages and the assistant's replies) continues to work as before, so you can still select and copy any part of a conversation.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.39...v7.40
