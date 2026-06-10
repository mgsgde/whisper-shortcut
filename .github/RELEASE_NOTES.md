# WhisperShortcut 7.58

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Transcription

- **Snappier dictation when you pause before pressing Stop.** The 200 ms tail-capture delay is now skipped automatically when the microphone has been quiet for the last ~400 ms — there's no tail to catch, so you get your result that much sooner.
- **One less duration probe per long recording.** The audio-duration lookup is shared between the chunking decision and the splitter, instead of being run twice.

### Fixes

- Fixed a small leak where each silently-rejected recording was kept in an in-memory tracking set forever.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.57...v7.58
