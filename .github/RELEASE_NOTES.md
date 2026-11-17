## Setup
- **Try it with your real key:** the "Try it now" step asks you to press your actual dictation key (🌐 or your shortcut), and the text lands right in the window. "Test with a button instead" keeps the old way.
- "Dictation only" setup ends after the successful test, without the glossary step.
- Until setup is finished, the menu bar menu shows only Status, Finish setup…, Settings… and Quit.

## Shortcuts
- Settings → General shows each shortcut as one control with keycaps. Dictate comes first, then the Fn switch; shortcuts you have not set sit behind "More shortcuts".
- Modifier keys are shown in the same order everywhere: ⌃⌥⇧⌘.
- The Fn switch shows as off while Accessibility is missing, with an Allow button.

## Dictation
- "äh", "ähm" and "öhm" are removed from every dictation, not only from Dictate Live.
- Glossary: a misheard form that is not a real word is corrected anywhere in the text, not only after "Frau" or "Dr.". Offline dictation (Parakeet) no longer replaces real German or English words with glossary terms.

## Dictate Prompt
- Works during a live meeting too: the quick prompt card appears, and clicking an entry or typing an instruction replaces the spoken one.
- If the spoken instruction is only "Mhm" or "Ah", nothing is changed and "Didn't catch that" appears.
- Local models no longer produce Cyrillic look-alike letters inside words.

## Fixes
- While Read Aloud plays, ⌘ shortcuts and typed keys reach the app in front (needs Accessibility).
- Stopping a live meeting no longer hangs for up to 30 seconds after a cancelled piece.
- Turning off "Dictation only" keeps the settings you changed after setup.
- An MCP glossary update that only partly fits now adds the terms that fit.
- Model import refuses with a clear message when the model is already there or still downloading. Deleting Parakeet keeps the voice detection model.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.95...v8.96
