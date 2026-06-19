# WhisperShortcut 7.71

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Stability: fixes for the app freezing during chat
This release targets the long-standing issue where the app could freeze (and appear to crash) — most often while a chat reply was streaming.

- **Fixed chat-streaming freeze.** Long replies could pin the main thread as the message list re-laid out on every streamed token. Streaming UI updates are now throttled, which removes the layout/parse storm that wedged the app while keeping the reply visibly live.
- **Fixed Keychain-related freeze.** Credential checks (e.g. for unconfigured providers) repeatedly hit the system Keychain on the main thread, which could block for seconds. These reads are now cached — including the "no key stored" result — so they no longer stall the UI.
- **Better freeze diagnostics.** The built-in hang watchdog now tags each captured hang report with what the app was doing at the time, making future issues faster to pinpoint.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.70...v7.71
