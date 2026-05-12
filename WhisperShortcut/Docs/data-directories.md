# WhisperShortcut Data Directories

WhisperShortcut stores user data locally on your Mac. The app intentionally uses one canonical Application Support location so sandboxed and non-sandboxed builds can share the same settings, context files, meeting transcripts, and downloaded models.

## Canonical Path

```text
~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/
```

This path is used for:

- `UserContext/`: interaction logs, user context, system prompts, and prompt history.
- `Meetings/`: saved live meeting transcripts.
- `WhisperKit/`: downloaded local Whisper models.
- Chat/session data and other app support files.

## Why The Path Looks Sandboxed

App Store builds are sandboxed by macOS and naturally resolve Application Support inside the app container. Non-sandboxed development builds explicitly use the same container-style path so switching between build variants does not split user data across two locations.

## Cleaning Or Resetting Data

Prefer the reset and delete actions in Settings when available. For manual cleanup:

1. Quit WhisperShortcut.
2. In Finder, choose Go > Go to Folder.
3. Paste the canonical path above.
4. Delete only the folder you intend to reset, such as `UserContext/` or `Meetings/`.

API keys and Google OAuth refresh tokens are stored in macOS Keychain, not in this directory.
