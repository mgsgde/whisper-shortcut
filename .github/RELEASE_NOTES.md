## Dictate Live
- **Text arrives reliably in Chrome.** In Chrome, Edge, Brave, Arc and other Chromium browsers, Dictate Live now types each piece instead of pasting it, because these browsers sometimes dropped a paste. In other apps, WhisperShortcut checks that each piece arrived and pastes it once more if it did not.
- **The next dictation continues the last one.** A second Dictate Live in the same app now gets a space and the right capitalisation, even when the app does not let WhisperShortcut read the cursor. This is forgotten as soon as you click, type or switch apps.

## Spoken punctuation
With Punctuation set to "Only when spoken":
- Commas and periods the model sets are kept only where you actually paused. Guessed question and exclamation marks are dropped.
- After a dropped period, the next word is no longer capitalised ("mal weiter" instead of "mal. Weiter").
- A comma glued to the next word gets its space.

## Chat
- **Fixed a freeze.** The Chat window could hang with high CPU when it showed meeting notes, a banner or the mail sign-in card.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.78...v8.79
