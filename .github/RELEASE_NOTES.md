**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Claude & other AI apps
- **Problem reports.** When an AI app tuning your setup finds a mistake no setting can fix (the instructions already forbid it, or the bug is in the app), it now saves a problem report instead of adding yet another rule. It opens in a window where you can remove anything private, then open it as a GitHub issue or discard it. Nothing is sent unless you submit the issue yourself.
- **Tidy long instructions.** The "tune my setup" recipe has a new `prompts` focus: the AI app compares each instruction section with the built-in default's length, starts with the one that grew most, and proposes a shorter version, one section at a time, for you to approve.

## Fixes
- Feedback links (WhatsApp, email, GitHub) keep `&` and `+` in your text. Before, "Anamnese & Befund" cut the message off at the `&`.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.58...v8.59
