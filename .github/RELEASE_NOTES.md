# WhisperShortcut 7.25

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Smart Improvement & Dictation

- **Smart Improvement scheduling was tightened.** First-run auto-triggering now starts as soon as enough interaction data is available, and cooldown handling no longer consumes cycles incorrectly.
- **Auto-run UX is cleaner.** Background Smart Improvement runs no longer show a misleading "started" popup while still reporting meaningful result notifications.
- **Empty transcriptions are handled explicitly.** No-speech chunks now produce a dedicated no-speech path instead of ambiguous empty-success behavior.

### Menu Bar

- **Settings row alignment was fixed.** Menu handling now avoids AppKit auto-decoration behavior that caused the gear icon/alignment issue in the status menu.

### Dependencies

- Merged dependency updates for `swift-collections`, `swift-jinja`, `gtm-session-fetcher`, and `swift-transformers`.

## Full changelog

[Compare v7.24…v7.25](https://github.com/mgsgde/whisper-shortcut/compare/v7.24...v7.25)
