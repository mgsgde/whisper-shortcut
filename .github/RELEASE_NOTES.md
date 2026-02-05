# Release v5.3.6

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### New Features

- **Live meeting transcription**: Record and transcribe meetings with a dedicated live meeting recorder. New settings tab and menu integration let you start/stop recording and manage where transcripts are saved.
- **Open transcripts folder**: New menu option to open the transcripts folder directly from the app.
- **Rate limit notifications**: Global rate limiting for chunk transcription and text-to-speech, with clear UI notifications when limits are hit so you know why requests are throttled.
- **Improved TTS flow**: Better clipboard handling and conversation history checks in the TTS (Read Aloud / Prompt & Read) flow.

### Improvements

- **Rate limiting**: Consolidated rate limiting logic across transcription services. TTS service now uses global rate limiting with improved error handling.
- **Live meeting settings**: Removed silent chunk handling from live meeting settings for a simpler configuration.
- **Transcription services**: Removed max concurrency settings; behavior is now driven by the global rate limiter.

### Other

- Dependabot configuration updated for npm and Swift package updates.
- `.gitignore` updated for Cursor-related files.

## Full Changelog

For a complete list of changes, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v5.3.5...v5.3.6).
