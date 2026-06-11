# WhisperShortcut 7.61

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Diagnostics

- **Save raw assistant responses to disk.** New opt-in toggle in Settings → General (Reset section): when enabled, each final chat reply is written as a `.md` file under Application Support so markdown-rendering bugs can be reproduced from the exact model output. Off by default.

### Fixes

- **Multi-line numbered and bullet lists in chat.** List items that continue on indented lines (e.g. `1. **Heading:**` followed by a wrapped value on the next line) now render as a single bullet instead of falling back to plain text.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.60...v7.61
