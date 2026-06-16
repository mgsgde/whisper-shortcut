# WhisperShortcut 7.67

This release focuses on giving you full control over permissions and startup behavior, plus a more reliable AI chat experience.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Permissions & startup are now fully opt-in
- **Launch at Login is off by default.** The app no longer registers itself to start at login automatically — turn it on yourself any time in Settings → General.
- **Accessibility is optional.** It is used only for the optional auto-paste convenience (inserting dictated text at your cursor via a ⌘V keystroke). Auto-paste is now **off by default**, the Accessibility request was removed from onboarding, and dictation works fully without it (your text is always copied to the clipboard).
- **Clearer permission prompts.** The microphone setup button now reads "Continue", and the in-app descriptions of the Accessibility permission accurately reflect that it is used solely for auto-paste.

### More reliable AI chat
- Gemini chat streaming now **automatically retries transient failures** (HTTP 503/500/429) with exponential backoff before any output is shown, so temporary server hiccups and rate limits no longer interrupt a response.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.66...v7.67
