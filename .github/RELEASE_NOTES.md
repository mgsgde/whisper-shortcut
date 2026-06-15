# WhisperShortcut 7.66

Maintenance release that refreshes WhisperShortcut's underlying Swift dependencies to their latest patch versions. No user-facing feature changes.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Dependency updates
- Updated **swift-asn1** 1.7.0 → 1.7.1 (correct signed-integer encoding, OID initializer fix).
- Updated **swift-argument-parser** 1.8.1 → 1.8.2 (completion-script and build-warning fixes).
- These keep the app's cryptography and tooling stack current; no behavior changes for users.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.65...v7.66
