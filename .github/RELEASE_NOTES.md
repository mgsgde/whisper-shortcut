# WhisperShortcut 7.87

API keys no longer vanish, Claude joins the chat, and error messages finally tell you what's actually wrong.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 🔑 API keys no longer disappear

- **Non-destructive saving**: Keys are now updated in place in the macOS Keychain. Previously a failed save (locked or damaged login keychain) could silently delete your existing key — seen as "my API keys disappear".
- **No more silent wipes on tab switch**: A failed Keychain read can no longer blank the key field and overwrite your stored key with an empty value.
- **Visible errors**: If a key can't be stored, a red warning with the exact Keychain error code now appears under the field — and the key keeps working for the current session.

### 🧭 No more dead ends in model selection

- If an offline Whisper model is selected but was never downloaded, entering a cloud API key now automatically switches dictation to that provider's model instead of endlessly showing "download the model".
- The popup for a missing offline model is now titled **"Model Not Downloaded"** instead of the contradictory "API Key Required".

### 💳 Clearer billing and rate-limit errors

- Rate-limit messages no longer point everyone at Google — they now cover Google, OpenAI, and xAI with the right billing links.
- OpenAI's "no credit on the API account" error is now shown as **Billing Required** (with a note that a ChatGPT subscription does not include API credit) instead of a generic rate limit.

### 💬 Claude in Chat

- Anthropic is now a first-class chat provider: add your Anthropic API key in Settings → General and pick a Claude model in the chat window.

### 📋 Clipboard paste cue

- After dictation, clipboard-only users (including the App Store build) get an explicit **⌘V** hint so it's clear the text is ready to paste.

### 🎤 Dictation quality

- Glossary terms are now framed as reference-only with a plausibility gate, preventing very short or unclear audio from echoing glossary terms into the transcript.
- The glossary fast-learner no longer learns grammatical variants (e.g. German plurals) as if they were misspellings.
- Chatbot-style refusals ("please send the audio") are detected and surfaced as "no speech detected" instead of being pasted.

### 🛠 Fixes & maintenance

- Smart Improvement: dictation audio is captured before transcription starts, fixing a race where rapid consecutive recordings lost ~2% of captures.
- Dictate Prompt: "korrigiere" instructions preserve register, casing, and line breaks instead of formalizing casual text.
- Chat: no more decorative line prefixes on paste-ready output; UTF-8 mojibake in pasted text is repaired.
- Google Tasks: due dates are normalized to RFC 3339, fixing recurring 400 errors.
- Model updates: OpenAI chat models migrated to gpt-5.4 / gpt-5.4-mini.
- Onboarding and privacy copy now surface the fully offline Whisper + Ollama setup.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.86...v7.87
