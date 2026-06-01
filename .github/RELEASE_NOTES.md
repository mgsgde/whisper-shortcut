# WhisperShortcut 7.45

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Fixed: chat freeze on long, streaming answers

- Fixed a bug where the chat could lock up at 100% CPU — the answer would stop updating with the stop button stuck on and a `…` spinner that never finished. It was most reliably triggered by **switching chats while a long, formatted reply was still streaming**. The selectable-text overlay AppKit puts over a streaming answer could enter an endless layout loop and wedge the main thread, which also left the message stuck in its "generating" state. Finished answers stay fully selectable and copyable.

### Changed: more attachments per message

- You can now attach up to **10** files (images, PDFs, etc.) per chat message, up from 5.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.44...v7.45
