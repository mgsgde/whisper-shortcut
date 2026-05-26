# WhisperShortcut 7.27

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Menu bar polish

- **Native-looking menu bar icon.** The idle state now uses a system SF Symbol (`mic.fill`) rendered as a monochrome template image at 16pt, so the app blends in with Apple's own menu bar icons (Wi-Fi, Spotlight, Control Center) instead of standing out as a colored emoji.
- **Recording, processing, and feedback states unchanged.** The colored status indicators you rely on for visual feedback (🔴 recording, ⏳ processing, ✅/❌ results) still appear as before — only the resting "ready" icon was updated.
- **Smoother blinking.** Active states now pulse via opacity rather than swapping the title in and out, which avoids a brief reflow of neighboring menu bar items.

## Full changelog

[Compare v7.26…v7.27](https://github.com/mgsgde/whisper-shortcut/compare/v7.26...v7.27)
