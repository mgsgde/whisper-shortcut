# WhisperShortcut 7.68

This release brings the Mac App Store build into compliance with Apple's review guidelines. **If you use the direct download from this page, nothing changes** — all of its features behave exactly as in 7.67. The changes below apply to the **Mac App Store** build only.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Mac App Store build is now Accessibility-free
To meet App Store Guideline 2.4.5, the App Store build no longer uses the macOS Accessibility permission at all:
- **Dictate Prompt** reads your selected text from a screenshot (Screen Recording permission) instead of copying it with a synthesized ⌘C keystroke.
- **Auto-paste** is removed in the App Store build; the result is placed on the clipboard for you to paste.
- **Read Aloud of the current selection** (the menu item / global shortcut) is removed in the App Store build. Read Aloud inside the Chat window is unaffected.

The direct/GitHub download keeps the full feature set — ⌘C-based Dictate Prompt, auto-paste, and selection Read Aloud all remain.

### Onboarding
- The Screen Recording permission button now reads **"Continue"** instead of "Grant" (Guideline 5.1.1).

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.67...v7.68
