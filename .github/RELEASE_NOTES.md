# Release v6.3.0

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### New Features

- **Improve from voice**: New shortcut (default Cmd+6) to record a voice instruction and improve system prompts for User Context, Dictation, Dictate Prompt, and Prompt & Read. Voice-triggered Smart Improvement runs in the background with optional auto-paste of improved sections.
- **Context tab**: Smart Improvement has been renamed to **Context**. The Context tab manages context data and system prompts, with options to edit prompts in Settings, open the context data folder, and reset system prompts to defaults.

### Improvements

- **Improve from voice behavior**: Clipboard now receives only the sections that were actually improved. Auto-paste after improvement follows the Auto-paste setting. Indentation and bullet points are preserved when pasting. No auto-paste when using clipboard-only (message) mode.
- **Context / system prompts**: System prompts are stored and edited via a dedicated store; legacy UserDefaults usage removed. Improvement runs are queued so multiple requests are handled sequentially. UI shows improvement state and queued job count. Reset system prompts to defaults after deleting context data.
- **Model selection**: All model selections (transcription, prompt, prompt & read, TTS, improvement) are persisted across restarts and survive validation failures. Dictate Prompt and Prompt & Read default to Gemini 3 Flash. Smart Improvement default model is Gemini 3 Flash.
- **Recording safeguards**: Default confirmation duration for recording safeguards increased from two minutes to five minutes.
- **Settings & docs**: Keyboard Shortcuts section moved to top of General. Context data button label and help text simplified. Documentation structure updated; obsolete docs removed. Removed unused verify-reset-interaction-data script.

### Fixes

- _(None called out in this release.)_

## Full Changelog

For a complete list of changes, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v6.1.0...v6.3.0).
