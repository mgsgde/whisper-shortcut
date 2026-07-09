# WhisperShortcut 7.85

Google Calendar chat tools now support recurring and all-day events.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 📅 Google Calendar — recurrence & all-day events

- **Recurring events**: Ask chat to create or update repeating calendar entries — yearly birthdays (`RRULE:FREQ=YEARLY`), weekly standups, weekday-only series, and more via standard RFC-5545 recurrence rules.
- **All-day events**: Birthdays, holidays, and full-day blocks no longer need a start/end time — set `all_day` and pass a date like `2026-07-09`.
- **Smarter date handling**: Single-day all-day events automatically get the correct exclusive end date per the Google Calendar API.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.84...v7.85
