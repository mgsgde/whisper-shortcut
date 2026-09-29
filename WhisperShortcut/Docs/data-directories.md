# WhisperShortcut Data Directories

WhisperShortcut stores user data locally on your Mac. The app intentionally uses one canonical Application Support location so sandboxed and non-sandboxed builds can share the same settings, context files, meeting transcripts, and downloaded models.

## Canonical Path

```text
~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/
```

This path is used for:

- `UserContext/`: interaction logs, user context, system prompts, prompt history, short-lived Smart Improvement audio verification samples in `UserContext/audio-samples/`, and the Writing Style profile and example messages in `UserContext/writing-style/` (`profile.md`, `samples.jsonl`).
- `Meetings/`: saved live meetings. Each one is up to three files sharing a stem: `<meeting>.txt` (the transcript), `<meeting>.notes.md` (the live notes taken during the meeting), and `<meeting>.summary.md` (the summary written when it ended).
- `WhisperKit/`: downloaded local Whisper models.
- `telemetry-pending.json`: opt-in anonymous usage statistics not yet sent (counts only). Exists only while "Share anonymous usage statistics" is on; deleted when it is turned off. See `WhisperShortcut/Telemetry/TelemetryService.swift`.
- Chat/session data and other app support files.

## Why The Path Looks Sandboxed

App Store builds are sandboxed by macOS and naturally resolve Application Support inside the app container. Non-sandboxed development builds explicitly use the same container-style path so switching between build variants does not split user data across two locations.

## Cleaning Or Resetting Data

Prefer the reset and delete actions in Settings when available. For manual cleanup:

1. Quit WhisperShortcut.
2. In Finder, choose Go > Go to Folder.
3. Paste the canonical path above.
4. Delete only the folder you intend to reset, such as `UserContext/` or `Meetings/`.

API keys, Google OAuth refresh tokens, and Trello tokens are stored in macOS Keychain, not in this directory.

Smart Improvement audio samples are only created when **Save usage data** is enabled. They are capped, used as verifier evidence for dictation-related suggestions, and deleted at the start of the next Smart Improvement run or when interaction data is deleted.
