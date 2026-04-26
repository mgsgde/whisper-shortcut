# WhisperShortcut 7.3

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Build and release reliability

- **Shared app metadata**: Both the standard and App Store targets now use the same `Info.plist`, keeping version numbers, bundle metadata, and Google OAuth callback configuration aligned.
- **Release signing fix**: Removed a conflicting manually specified provisioning profile from the automatically signed release configuration, so GitHub release builds and App Store builds can both compile cleanly.

### Release tooling

- **Version command cleanup**: The release helper command now updates the single shared `WhisperShortcut/Info.plist`.

## Full changelog

[Compare v7.2…v7.3](https://github.com/mgsgde/whisper-shortcut/compare/v7.2...v7.3)
