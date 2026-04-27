# WhisperShortcut 7.6

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Bug fixes

- **Meeting button now starts on the right chat**: Starting a live meeting from a new chat after a previous one ended no longer attaches the recording to the old session. Each new meeting starts fresh on the current chat, and the Resume button on a finished meeting still continues that meeting.
- **"Reset all to defaults" really resets everything**: Chat sessions, meeting transcripts, and the system-prompts file are now wiped along with settings and interaction data. API keys and Google OAuth tokens stay safely in the Keychain. The confirmation dialog text was updated to accurately reflect what gets deleted.

### Reliability

- **Gmail**: Search-result detail fetches are now batched (max 8 in flight) so opening a large search no longer overloads the API.
- **Google OAuth**: Token request bodies use stricter form-URL encoding, fixing edge cases where special characters in codes or tokens could break the exchange.
- **Google Calendar**: Event-ID encoding for deletes is stricter, avoiding malformed URLs for IDs that contain reserved characters.

### Code quality

- Removed obsolete duplicate toggle-enabled state in settings — the shortcut config is now the single source of truth.
- General cleanup across chat, tools, calendar API, rate limiting, and meeting list code.

## Full changelog

[Compare v7.5…v7.6](https://github.com/mgsgde/whisper-shortcut/compare/v7.5...v7.6)
