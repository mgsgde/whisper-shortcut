**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Correct, Format and Rephrase are gone from the menu

They shipped in 8.09 without ever being reviewed on their own, and they did not earn the three rows they cost. Each one still started a recording, so "one-tap" was never true, and none of them had a shortcut. All three only prefixed a sentence onto the Dictate Prompt instruction — something you can say yourself.

**Nothing is lost.** Dictate Prompt still does all three: press the shortcut and say "correct this", "format this" or "rephrase this". The menu is the app's whole surface, and it is three rows shorter now.

## Offline Mode also covers the update check

The direct-download build asks GitHub whether a newer release exists. That one request went out through a connection Offline Mode did not guard, so with the switch on it could still reach the internet — the only call in the app that could. It now goes through the same guard as everything else.

This never affected the App Store build, which does not contain the update check at all. Downloading a Whisper or MLX model from Hugging Face still works while Offline Mode is on, as documented: that download carries no content of yours.

### Also in this release

- The App Store review prompt used a StoreKit entry point that macOS has deprecated since 15.0 — the app's own minimum. It now uses the current one, and a prompt that cannot be shown stays pending instead of being silently spent.
- Measured where offline Whisper actually spends its fixed cost per dictation, so the "local transcription feels slow" question stops being re-investigated from scratch. No behaviour change.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.10...v8.11
