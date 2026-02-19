# Release v6.0.0

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### New Features

- **Smart Improvement**: System prompts (Dictation, Speech-to-Prompt, Prompt & Read) can now improve automatically based on your usage. Configure how often improvements run and which model is used. First run skips cooldown; default “improvement after N dictations” is 20.
- **User context & history**: User context and system prompts are derived and stored with configurable limits. Dictation and User Context get system prompt and user context history; “Generate with AI” is available per tab with primary-mode history. Analysis uses Gemini 2.5 Pro for better accuracy.
- **Prompt areas**: “Reset to Default” in all prompt areas; system prompt editor height increased for easier editing.
- **Live Meeting**: Duration safeguard (pop-up after 60/90/120 min), always-on timestamps, and consistent naming. New option to open the transcripts folder from the app.
- **Settings**: Open Interactions Folder and Open Transcript Folder aligned across tabs. Autopaste default, notification position (top-left), and clearer reset-to-defaults flow (app quits after reset). Removed “Difficult Words” and the Smart Improvement compare sheet for a simpler setup.

### Improvements

- **Data & paths**: Canonical Application Support path for both sandboxed and non-sandboxed runs. System prompt changes and JSONL history logged for transparency. Scripts for checking interaction count, resetting interaction data, and verifying reset behavior.
- **Stability & UX**: Command-1 cancels transcription in all phases (including splitting/chunks/merging). Chunk request timeout for transcription. Popup notifications and notification handling improved.
- **Codebase**: Removed AsyncSemaphore, shortcut validation logic, and transcript merging; consolidated user context handling and settings UI. Documentation for data directories, Smart Improvement flow, and Gemini system prompt best practices.

### Other

- Privacy policy and in-app copy updated (e.g. 30-day interaction disclosure, “Generate with AI” explanation). README and live meeting settings updated.

## Full Changelog

For a complete list of changes, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v5.3.6...v6.0.0).
