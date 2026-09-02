**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Offline dictation: a serious fix, and a big speed-up

**If you dictate offline with a Glossary, please update.** The Glossary was being handed to the on-device Whisper model as raw conditioning text, including its `Term (not "Wrong")` notes. Whisper treats that text as a writing sample to continue rather than as a rule list, so it learned to emit quoted, parenthesised fragments and fall into repetition loops. On one 64-second recording it returned **51 characters instead of 975** — most of the dictation simply lost. The Glossary is now cleaned up before it reaches Whisper: the terms are passed through exactly as you wrote them, the annotations and quotation marks are not.

**Offline dictation now transcribes while you speak.** Sections of your recording are transcribed at natural pauses as you go, so pressing Stop usually leaves only the last section to process. On a 73-second dictation with pauses the wait after Stop dropped from about 20 seconds to 4–6. How much you gain depends on how you speak: a dictation with several pauses gains a lot, one long unbroken stretch gains little, because the final section still has to be transcribed.

### Also in this release

- A recording is no longer abandoned if macOS unloads the speech model under memory pressure mid-dictation — it is reloaded and the dictation continues.
- Cancelling a dictation now stops the transcription immediately instead of letting it run to completion in the background.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.08...v8.09
