## Dictate Live
- **Line breaks no longer send.** Line breaks are typed as Shift+Return, so a new line in Chrome, web forms or chat apps no longer submits or sends the message.
- **No update window in the middle of dictation.** If an update is ready while you dictate, WhisperShortcut waits until you have finished before showing it.
- **Pressing the shortcut again no longer loses text.** A second press while the last pieces are still being inserted is ignored instead of discarding them.

## Offline dictation with spoken punctuation
- A spoken comma before "neue Zeile" or "neuer Absatz" is kept.
- "Klammer auf" followed by an article becomes "(" when a "Klammer zu" follows.
- "Punkt" after "ein", "zu", "in" or "einen" is written as a full stop, unless a number or noun follows.
- After a salutation and a comma, the next line starts in lower case.
- The glossary no longer replaces everyday words or the first part of a compound word.
- Commas, question marks and exclamation marks are kept more reliably, and never more than one blank line appears between two pieces.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.86...v8.87
