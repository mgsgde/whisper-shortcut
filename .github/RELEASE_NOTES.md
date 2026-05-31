# WhisperShortcut 7.41

A reliability release focused on the menu-bar shortcuts: Read Aloud, screenshots, live meetings, and the review prompts.

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Read Aloud
- **No more clipped or stale text.** Instead of waiting a fixed moment after copying your selection, Read Aloud now waits for the clipboard to actually update — so slower apps no longer get cut off, and fast ones don't stall.
- When you trigger Read Aloud without selecting any text, you now get a brief, friendly "No text selected" note instead of an error.

### Screenshots
- The global screenshot shortcut once again **saves captures to your chosen folder** (not just the clipboard).
- If macOS Screen Recording permission is missing, the app now tells you clearly and offers a direct link to System Settings, instead of failing silently.

### Live Meetings
- Meeting titles now appear in the chat sidebar as soon as the summary is ready, rather than after a delayed recovery step.
- Hardened the meeting and dictation flows so model/credential checks are consistent and final-chunk processing runs safely on the main thread.

### Review & Support Prompts
- Restored the menu-open prompts so review and support reminders surface again at the right moment.

### Under the Hood
- Chunked synthesis now shows a "Synthesizing Speech" status during retries.
- Internal cleanup: removed dead state and unused settings paths, and consolidated repeated menu-bar logic into single, shared helpers.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.40...v7.41
