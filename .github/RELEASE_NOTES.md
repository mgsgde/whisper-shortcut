# WhisperShortcut 7.76

Live Meeting cost and reliability release.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Improvements
- **Live Meeting uses far fewer API calls.** The default transcription interval is now 60 seconds (fewer chunk requests), and the live summary updates on demand — only when you open the Summary tab or chat with an active meeting — instead of on a fixed timer. The final meeting summary is unchanged.
- **Easier meeting management from the sidebar.** Improved archive actions for meetings.
- **Faster, clearer AI errors.** When a provider returns a permanent rate/quota error with no retry hint, WhisperShortcut now fails fast with a clear message instead of retrying for a long time.
- **Sharper Smart Improvement suggestions.** Capitalized terms are now ranked by how consistently they're capitalized across your usage.

### Fixes
- **Fixed a chat freeze during streaming replies.** The streaming bubble is now detached from the list layout so long, fast responses no longer wedge the main thread.
- **More reliable live meeting summaries.** Summary writes are guarded with a per-session token so a straggling update from a previous meeting can no longer write into the current one.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.75...v7.76
