# WhisperShortcut 7.97

Using OpenRouter no longer involves an API key at all — you sign in once and the app takes care of the rest, for both dictation and chat.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 🔗 Connect OpenRouter with one click

Connecting a provider used to mean visiting a dashboard, generating a key, and pasting it into Settings. For OpenRouter that step is gone.

- **Sign in instead of pasting.** Available in onboarding and in Settings → General. You approve access at OpenRouter — the same flow creates the account if you don't have one — and the app receives its key directly. You never see it, and you pay OpenRouter directly for what you use.
- **One connection covers dictation and chat.** Press **Use OpenRouter preset** in Settings → Chat and there is no key to enter there either.
- **Pick models from a list instead of typing slugs.** The list is fetched live from OpenRouter and filtered to models that actually accept audio, with rough prices shown, so new models appear as OpenRouter adds them — no app update needed. A custom slug field remains for anything the list doesn't cover.
- **Running out of credit now tells you where to top up** instead of failing with a generic billing message.

### 🎛️ A clearer transcription model picker

The grid used to split into "Cloud" and "Offline", which hid the distinction that actually mattered: a model reached **directly** with that provider's key, versus the same model reached **through a router**. Gemini 3.5 Flash-Lite could appear both as a tile and inside OpenRouter's own model list, with nothing saying which account each one bills.

Models are now grouped as **Direct**, **Routed** and **Offline**, and routed entries show where they point — for example `OpenRouter → Google: Gemini 3.5 Flash Lite`. The chat model chip is shorter too, so the slash-command row beside the composer no longer gets squeezed.

### 🐛 Fixes

- Chat could fail with "API key is invalid for the custom endpoint" right after a successful OpenRouter sign-in, because a key left over from a different proxy was preferred over the connected account. The endpoint-specific credential now wins, and Settings → Chat states which one is actually in use.
- Long, tool-heavy chat turns no longer lose the final answer.
- Dictation history records whether a dictation actually succeeded, not just what it produced.
- The usage review says it couldn't read the log instead of reporting a "quiet week".
- Support and feedback are reachable from where users already are.

### 🧹 Under the hood

- Transcription providers are a first-class concept now, instead of four hand-maintained boolean checks repeated in three places that had to agree. Stored settings are unchanged.
- The chunked transcription and text-to-speech pipelines share their retry and result-collection logic instead of keeping two copies of it.
- Text-to-speech playback and the chat message action buttons moved into types of their own.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.96...v7.97
