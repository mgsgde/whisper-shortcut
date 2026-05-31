# WhisperShortcut 7.44

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Removed: "Pause media while recording"

- The experimental *Pause media* setting briefly introduced in 7.43 has been removed. It relied on the system play/pause key, which is a toggle, and since macOS 15.4 third-party apps can no longer detect whether media is actually playing. As a result it could accidentally **start** a paused video when you began a recording — the opposite of what it should do. There is no reliable, sandbox-safe way to fix this for arbitrary players, so the feature has been withdrawn.

> Note: Release 7.43 has been retired; please use 7.44 instead.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.42...v7.44
