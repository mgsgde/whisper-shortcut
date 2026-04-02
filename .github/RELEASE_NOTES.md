# Release v6.7

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Scope

- **Read Aloud, Prompt & Read mode, and Improve-from-voice** have been removed from the app. The product now focuses on Speech-to-Text, Speech-to-Prompt, and **Gemini Chat**.

### Gemini Chat

- **Prompt queue**: Queue multiple prompts so they run in order without losing work.
- **Prefill from selection**: Use the shortcut to open Gemini with the current text selection already placed in the composer.
- **Selection chips**: Shortcut-prefilled text is wrapped as clear **pasted selection** blocks so you can see what was sent.
- **Reliability**: Fixes for a crash related to main-thread rules, a focus-loss race, and the Open Gemini shortcut now **toggles** the window (closes it if it is already open).

### Speech-to-Prompt & dictation

- **Optional screenshot**: Prompt Mode can attach a screenshot **only when you opt in** (UserDefaults); the toggle lives under **Speech-to-Prompt** settings.
- **Auto-paste** for dictation is **opt-in**, so first-run permission prompts are less overwhelming.

### Other

- Streamlined default response guidelines in app constants.
- Internal cleanup: clearer naming in window management, removal of temporary prefill debug logging.

## Full Changelog

For a complete list of changes since v6.6.3, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v6.6.3...v6.7).
