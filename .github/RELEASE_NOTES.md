# WhisperShortcut 7.60

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Fixes

- **Cleaner chat formatting for labeled-list answers.** When the model emitted labels in the shape `**Heading** *(meta)*: value` (e.g. App Store-style metadata blocks like `**Untertitel** *(29 von 30 Zeichen)*: …`) with no separator from the preceding value, the renderer was running them into a single line and dropping the post-colon space. Each label now gets its own line and a normal space before its value.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.59...v7.60
