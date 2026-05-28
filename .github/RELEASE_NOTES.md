# WhisperShortcut 7.35

## What's new
- **Faster live meeting transcription.** Meeting audio is now split into 30-second chunks by default (was 60), so the transcript fills in roughly twice as often while a meeting is in progress.
- **Meetings get titled even if the window was closed.** If a meeting finished while no chat window was open, opening that meeting later now generates its title from the summary instead of leaving it untitled.

## Fixes
- The **Transcript** and **Summary** tabs in the meeting view are now clickable across their whole area, not just on the label text.

## Behind the scenes
- Code-review pass over the most-changed files: removed a duplicated live-meeting chunk-interval constant so the default lives in a single place, collapsed five repeated "read bool setting or fall back to default" blocks into one `UserDefaults` helper, and consolidated the three one-time shortcut migrations' shared "reset Settings only if still on an old default" check into a single named helper.

## Installation
Download the latest `.dmg` from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Full changelog

[Compare v7.34…v7.35](https://github.com/mgsgde/whisper-shortcut/compare/v7.34...v7.35)
