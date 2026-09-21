**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Dictate Prompt
- **Gemini 3.8 Flash is the new default model** for Dictate Prompt (was Gemini 3.5 Flash-Lite). Existing installs that never changed the model are moved over; a model you picked yourself stays as it is.

## Read Aloud
- **The progress bar no longer jumps back** while audio is still arriving. The total used to be "audio received so far", so on a long text the knob sat at 100 % after the first chunk and snapped back when the next one landed. The total is now estimated from the text length until the stream closes, the received region is drawn in a middle tone, and dragging stops at its end.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.19...v8.20
