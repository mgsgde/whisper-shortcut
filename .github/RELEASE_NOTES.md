# WhisperShortcut 7.82

Push-to-talk tuning and fixes: slow taps no longer stop your recording, and cancelled transcriptions stay cancelled.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 🎙️ Push-to-talk fixes

- **Slow taps no longer misfire**: The hold threshold was raised from 0.5 s to 1 s — an unhurried tap to start dictation (which can easily last 0.6–0.7 s) no longer counts as a push-to-talk hold, so releasing the key can't instantly stop the recording you just started. Genuine press-speak-release holds work as before.
- **Cancelled recordings stay cancelled**: Cancelling a transcription while it was processing could still paste the late result to the clipboard and flash a success popup. In-flight results for cancelled recordings are now dropped.
- **Quieter logs**: Cleanup of already-removed recording files no longer logs spurious warnings.

### 📖 Glossary

- **Learn from Dictate Prompt selections**: The text you select for Dictate Prompt is user-curated spelling — names and terms in it are now picked up by the instant glossary learner, just like typed chat messages.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.81...v7.82
