# WhisperShortcut 7.39

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### 🎙️ Choose a voice for Read Aloud

The Read Aloud settings now include a **Voice** dropdown, so you can pick the exact voice each provider uses instead of always getting a fixed default.

- Full voice catalogues: **30** Gemini voices, **13** OpenAI voices, and **5** Grok voices — each shown with a style hint and a gender label (m/w). Voices are listed male first, then female.
- Your choice is remembered **per provider**: switch from Gemini to OpenAI and back, and each keeps the voice you picked. If a stored voice is ever no longer offered, it falls back to that provider's default.

### 🧠 Set the thinking depth per chat with `/think`

A new `/think` command lets you set the reasoning depth for the current chat: `minimal`, `low`, `medium`, `high`, or `default`.

- The setting is saved per chat and stays in effect across restarts.
- It works across all chat providers (Gemini, OpenAI, Grok), each mapped to its native reasoning control.
- Type `/think` on its own to see the current level.

### 🔊 Better Read Aloud rewriting

The default "rewrite for speech" prompt now condenses and cleans up text more reliably and returns only the spoken version, so playback sounds more natural.

### 🐛 Fixes

- Fixed a chat issue where pressing Enter on a slash command could send the message to the wrong model.
- Fixed Gemini occasionally leaking raw reasoning tokens into chat replies.
- Settings now show the built-in default prompt when a prompt section exists but is empty.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.38...v7.39
