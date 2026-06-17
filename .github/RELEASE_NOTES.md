# WhisperShortcut 7.69

**If you use the direct download from this page, nothing changes** — all of its features behave exactly as before. The user-facing changes below apply to the **Mac App Store** build only.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Dictate Prompt reliability fix (App Store build)
In the App Store build, Dictate Prompt reads your selected text from a screenshot. If you picked an audio-only model that can't see images, the request used to go out empty and produce garbage. The app now stops with a clear message asking you to switch to a Gemini Dictate Prompt model.

### App Store build cleanup
The selection-based Read Aloud shortcut, menu item, and related settings are now fully compiled out of the App Store build (they rely on the macOS Accessibility permission, which that build does not use). Read Aloud inside the Chat window is unaffected. The direct/GitHub download keeps the full feature set.

### Internal
Consolidated the Dictate Prompt permission handling and clarified naming around the screenshot-based selection mode.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.68...v7.69
