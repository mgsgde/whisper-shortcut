# WhisperShortcut 7.95

Programmable keyboards can bind F17 (and other F-keys) on their own, auto-paste can leave your previous clipboard alone, and Read Aloud starts speaking as soon as the first chunk is ready.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### ⌨️ Shortcuts

- **F1–F20 bind without a modifier.** Use a dedicated QMK/VIA key (e.g. F17) for Dictate — press once to start, press again to stop. Shortcut labels for function keys and Space now show correctly instead of a blank glyph.

### 📋 Clipboard

- **Restore clipboard** (Settings → General → Clipboard Behavior, with Auto-paste on): after the result is pasted, your previous clipboard contents come back. Off by default so a second ⌘V into another window still works when you want it.
- **Copy Last Transcription** and a **Recent Transcriptions** submenu (last 5) in the menu bar — recover a dictation when paste went to the wrong place or something else overwrote the clipboard.

### 🔊 Read Aloud

- **Long text starts speaking when the first chunk is ready**, instead of waiting for the full synthesis.
- **Markdown, links, citation markers, and code fences are stripped** before TTS — especially useful when reading chat replies aloud.

### 🎤 Dictation quality

- Whisper Glossary `Term (not "Wrong")` entries act as **homophone tie-breakers**, and rejected spellings can be corrected after transcription.
- Fast or dense speech is less often discarded as “implausible”; near-silent chunks that only echo the glossary are dropped.
- Live Meeting no longer flashes a **Processing Audio** popup on every background chunk rotation.

### ⚙️ Settings

- The **Recommended** model star on Chat / Smart Improvement / Dictate Prompt pickers now matches each feature’s real default.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.94...v7.95
