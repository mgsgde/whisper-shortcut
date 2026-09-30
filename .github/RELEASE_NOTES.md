**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Works without an API key
- **Dictate Prompt and Chat now work offline without any key.** If you have no cloud API key and your Mac has Apple Silicon, both use the on-device model Qwen3 4B Instruct (about 2.3 GB). The offline path in onboarding downloads it in the background and shows the progress.
- If you add a key before you have used the offline model, Dictate Prompt and Chat move to your provider's model. Once you have used the offline model or turned on Offline Mode, the app never switches you to the cloud on its own.

## Dictation
- **GPT Transcribe is the new default and recommended cloud dictation model.** In our measurements it never invented text on silence, recognized glossary terms most reliably and was the fastest at every recording length. It is a pure speech-recognition model: filler-word removal and formatting instructions in the dictation prompt do not apply to it, while your Glossary does. If you only have a Gemini key, dictation uses Gemini 3.1 Flash-Lite.

## Offline models
- **Qwen3 8B (Offline) was removed.** The smaller Qwen3 4B Instruct followed the rules of our Dictate Prompt benchmark more closely (34 of 36 vs 30 of 36) and answers about twice as fast. If you had selected Qwen3 8B, the app switches you to Qwen3 4B Instruct — still offline — and deletes the 8B files (about 4.5 GB).

## Under the hood
- Updated swift-asn1 to 1.7.3.
- The README lists the prerequisites for building from source.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.28...v8.29
