# Release Notes for Version 5.2.4

## Installation

Download the latest version from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases) or update through the App Store.

## Changes

### 🎙️ Text-to-Speech (TTS) Functionality

This release introduces a powerful new Text-to-Speech feature that allows you to have selected text read aloud using high-quality voice synthesis.

**New Features:**

- **Read Selected Text**: Select any text in any application and have it read aloud with a customizable keyboard shortcut
- **Configurable Shortcut**: Set your preferred keyboard shortcut for the "Read Selected Text" feature in Settings
- **Voice Selection**: Choose from a variety of system voices in the Settings menu
- **Playback Controls**: Start, pause, and cancel audio playback directly from the menu bar
- **Smart Error Handling**: Improved error messages and logging for better troubleshooting

**Technical Improvements:**

- Enhanced MenuBarController with comprehensive TTS command handling
- Updated SpeechService to support TTS requests and cancellation
- Refactored settings and UI components for better TTS integration
- Improved audio duration validation before transcription
- Better file size and text validation constants for clarity

**User Experience:**

- Updated menu terminology to "Prompt & Read" for better clarity
- Streamlined menu bar interface for TTS operations
- Enhanced error handling and user feedback

## What's Next

We're continuously working on improving WhisperShortcut. If you have suggestions or encounter any issues, please [open an issue](https://github.com/mgsgde/whisper-shortcut/issues) on GitHub.

---

**Full Changelog**: [5.2.3...5.2.4](https://github.com/mgsgde/whisper-shortcut/compare/v5.2.3...v5.2.4)
