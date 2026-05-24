# WhisperShortcut 7.26

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Smart Improvement

- **Quieter background runs.** The brief "Smart Improvement started" popup no longer appears for auto-runs that fire on their own — only meaningful result notifications show up now.

### Dictation & Prompts

- **Sharper default system prompts.** Default prompts for dictation and chat were tightened for more accurate transcription and fewer formatting surprises.
- **Prompt-mode model now logged.** The model used for each prompt-mode call is recorded alongside the interaction, so quality issues can be attributed to the right model when reviewing local logs.

### Under the hood

- Audited the project's Cursor / Claude context files (`.cursor/commands`, `.cursor/rules`, `.cursor/skills`). Removed stale references, corrected service-name and path drift in the always-applied repo rule, reconciled the audio-verification skill's log-pattern table with the strings the app actually emits, and consolidated overlapping model-doc skills.

## Full changelog

[Compare v7.25…v7.26](https://github.com/mgsgde/whisper-shortcut/compare/v7.25...v7.26)
