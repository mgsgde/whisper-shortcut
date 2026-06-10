# WhisperShortcut 7.55

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Live Meeting

- **Stop button fix.** Pressing Stop mid-segment no longer drops captured audio; the segment is transcribed and the spoken tail is preserved.
- **Rolling summary tuning.** Chunk threshold for live rolling summaries is now centralized in app constants.

### Meeting Chat

- **Live summary scoping.** A live meeting's rolling summary no longer leaks into an ended meeting's chat tab.
- **Recovery gating.** Summary recovery no longer races the main sidebar when the floating Meeting Chat is open.
- **Simpler summary cache.** Ended-meeting summaries read from disk directly instead of a redundant in-memory cache.

### Under the hood

- **Meeting library cleanup.** Removed unused meeting-file APIs and collapsed summary URL/save helpers.
- **Release tooling.** Full test suite now runs before tagging a release.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.54...v7.55
