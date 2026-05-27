# WhisperShortcut 7.30

## Read Aloud (new)
- Select text anywhere and press the Read Aloud shortcut (default **⌘4**) to hear it spoken. Press again to stop — Stop also cancels an in-flight rewrite.
- **Smart Rewrite** (optional, on by default): Gemini converts non-prose content like code, tables, and markdown into a speakable form before TTS; plain prose passes through unchanged.
- **Playback speed**: 0.75× / 1× / 1.25× / 1.5× / 1.75× / 2×, applied locally with pitch preserved.
- Editable rewrite prompt in the new **Read Aloud** settings tab.
- The Settings shortcut moved from ⌘4 to ⌘5 to make room. Custom Settings shortcuts are untouched — only users who still had the default ⌘4 are migrated.

## Shortcut Recording
- Shortcuts are now captured by **pressing them**, not by typing key names. Works correctly on any keyboard layout — the recorder shows the letter printed on your physical keyboard.
- **Conflict resolution**: recording a combo that's already bound no longer dead-ends with a red error. The recorder shows what's currently using the combo and offers a one-click **Reassign**.
- Global hotkeys pause briefly while a row is recording so the combo you press is actually captured (and not fired as the other action).

## Polish
- Menu bar microphone glyph shrunk to 14pt so it no longer clips on small status bars.

## Installation
Download the latest `.dmg` from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Full changelog

[Compare v7.29…v7.30](https://github.com/mgsgde/whisper-shortcut/compare/v7.29...v7.30)
