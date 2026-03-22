# Release v6.6.2

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Stability

- Fixed excessive disk writes that could lead macOS to terminate the app.

### Release & signing

- Streamlined CI provisioning profile setup for more reliable release builds.

### Google Sign-In

- Updated Google Sign-In configuration in `Info.plist` and refactored `GoogleAuthService` to align OAuth scopes with the Whisper Shortcut API.

### Permissions & automation

- Clearer error handling and messaging for screen capture and auto-paste.

### Gemini Chat

- Added `/context` command support; removed the improve-from-voice flow from chat.
- Refined chat UI and Markdown block rendering for easier reading.

## Full Changelog

For a complete list of changes since v6.6.1, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v6.6.1...v6.6.2).
