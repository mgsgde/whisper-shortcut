**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Dictate Prompt
- **Fixed: an old clipboard is never used as your selection.** If nothing was selected when you pressed the shortcut, Dictate Prompt used to work on whatever was still on the clipboard, for example text you had copied earlier. It now only uses text you actually selected for this recording.
- **Nothing selected? It writes instead of editing.** With no selection, your spoken instruction is carried out as a new text (for example "write a short note that the appointment moves to Friday"), using only what you said, with no invented facts or names.

## Offline dictation
- **Spoken layout commands in German.** With offline models (Parakeet, local Whisper), "Doppelpunkt", "neuer Absatz" and "neue Zeile" become a colon, a paragraph break and a line break. "Punkt", "Komma" and "Fragezeichen" stay words.

## Chat
- **Faster answers by default:** Grok and GPT reasoning models now use low reasoning effort unless you change it with `/think`.
- **You can see when Grok or GPT is searching the web or X**, instead of bare dots.
- Fixed an error (HTTP 400) with Grok 4.20 models.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.34...v8.35
