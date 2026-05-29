# WhisperShortcut 7.36

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### One API key now unlocks every feature

WhisperShortcut is now fully multi-provider. Every feature — transcription, Dictate Prompt, chat, meeting summaries, Smart Improvement, and Read Aloud — works with **Gemini, OpenAI, or xAI**. Add a single provider's API key and the whole app just works:

- **xAI Grok Speech-to-Text** added as a transcription option.
- **Multi-provider Read Aloud (Text-to-Speech)** — pick a Gemini, OpenAI, or xAI voice.
- **Provider-agnostic Smart Improvement and Read Aloud Smart Rewrite** — these no longer require a Gemini key; they run on whichever provider you've configured.
- **Key-aware defaults** — when you add a key, features automatically switch to a provider you actually have access to, so you never get stuck on a "missing Gemini key" message with an OpenAI- or xAI-only setup.

### Screenshots: clear feedback when permission is missing

The global screenshot shortcut used to fail silently when macOS Screen Recording permission wasn't granted. It now detects the missing permission, shows an explanatory message, and links straight to the right System Settings pane.

### Chat sidebar

- Meeting date groups under the **Meetings** section are now collapsible.

### Reliability & under the hood

- Read Aloud now uses Google's current **Gemini 3.1 Flash TTS** model (the older 2.5 preview voices are being retired by Google); existing selections migrate automatically.
- Live meeting recording restores silence-based chunk rotation for more reliable long sessions.
- Various internal cleanups and build/signing improvements.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.35...v7.36
