# WhisperShortcut 8.07

**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

The App Store build now includes Correct, Format, and Rephrase. Offline Read Aloud finishes cleanly when there is nothing to speak.

## Fixes

- **Correct, Format, and Rephrase work in the App Store build.** Those menu items were already listed; their handlers had sat behind a gate meant only for selection-based Read Aloud, so the Mac App Store target did not compile.
- **Offline Read Aloud no longer hangs on empty text.** On-device macOS voices now finish instead of waiting forever when there is nothing to say.
- **Google sign-in refuses a broken login token.** If the random generator fails, the app no longer continues with an all-zero state.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.06...v8.07
