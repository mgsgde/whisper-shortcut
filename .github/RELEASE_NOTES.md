# WhisperShortcut 7.42

A small maintenance release with internal cleanup. No user-facing behavior changes — everything from 7.41 works the same.

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Under the Hood
- Consolidated the chat slash-command handling so the argument-taking commands (`/model`, `/think`) are recognized from a single source — preventing autocomplete and dispatch from ever drifting apart, and making future commands easier to add.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.41...v7.42
