# WhisperShortcut 7.21

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Added

- **⌘3 Screenshot shortcut**: Drag a rectangle and the screenshot lands on your clipboard — same UX as macOS's built-in ⌘⇧⌃4, just on a shorter chord. Available from the menu bar dropdown and configurable in Settings → Keyboard Shortcut.
- **Paste screenshots into Chat**: Native screenshots (⌘⇧⌃4) and the new ⌘3 capture both paste into the Gemini Chat composer as proper image attachments instead of inserting the file path as text.
- **Paste image and PDF files from Finder into Chat**: Copy a PNG/JPG/GIF/WebP/PDF in Finder and ⌘V in the chat composer now produces an attachment chip.

### Changed

- **Settings shortcut moved to ⌘4** to make room for ⌘3 = Screenshot. Existing users get a one-shot migration; rebind in Settings if you want a different combo.
- **Removed rarely-used slash commands** `/connect-google`, `/disconnect-google`, `/connect-trello`, `/disconnect-trello`. Connect and disconnect your accounts from Settings → Chat instead.

## Full changelog

[Compare v7.20…v7.21](https://github.com/mgsgde/whisper-shortcut/compare/v7.20...v7.21)
