# WhisperShortcut 7.22

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Fixed

- **Pasting large files no longer freezes the chat composer.** File pastes are now size-checked (≤20 MB) before being read into memory, so an accidental drag of a multi-GB PDF can't blow up the app.
- **"Use /connect-google" / "/connect-trello" messages now point to Settings.** After those slash commands were removed in 7.21, five error messages and the in-app README still told users to type them. They now read "Open Settings → Chat to connect."
- **Paste at the screenshot/file cap falls through to plain text instead of being silently eaten.** Hitting the 10-screenshot or 5-file limit during ⌘V used to consume the paste with no feedback.

### Internal

- File MIME detection in chat now uses `UTType` everywhere instead of two parallel hardcoded switches.
- Removed dead slash-command handling in `sendComposed` and consolidated the known-commands list to a single source of truth.

## Full changelog

[Compare v7.21…v7.22](https://github.com/mgsgde/whisper-shortcut/compare/v7.21...v7.22)
