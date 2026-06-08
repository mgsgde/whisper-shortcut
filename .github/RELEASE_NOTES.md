# WhisperShortcut 7.51

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Stability

- **Chat freeze hardening** — streaming replies that contain a generated image no longer re-process multi-megabyte image data on every token, and chat session writes are serialized on a dedicated disk queue. Both reduce the chance of the UI locking up during long conversations.
- **Automatic hang diagnostics** — a new main-thread watchdog detects if the app ever stops responding and automatically writes a diagnostic snapshot to the log folder, so freezes can be pinned down instead of guessed at.

### Chat & tools

- More reliable streaming, tool-call narration, and image-marker handling in chat.
- Generated-image attachments are now filtered to actual image types only.

### Google Calendar

- Calendar lookups can include past events, and dates supplied by the model are normalized for more accurate event creation.

### Transcription

- Instructable speech-to-text models now receive your glossary as a proper instruction block for better term recognition.

### Onboarding & Settings

- Streamlined first-run experience: the permissions step is combined and the guidance is clearer.
- Simplified API-key handling in Settings and removed unused model options.
- Clearer Screen Recording permission copy mentioning the Dictate Prompt screen context.

### Under the hood

- Tightened Smart Improvement context derivation and term extraction.
- Internal cleanups (model-selection reconciler, settings view model, file renames) and a dependency bump (swift-argument-parser 1.8.1).

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.50...v7.51
