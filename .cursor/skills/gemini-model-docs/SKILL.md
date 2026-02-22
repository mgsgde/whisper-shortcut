---
name: gemini-model-docs
description: Look up current Gemini model IDs and GA vs Preview status from official Gemini API (Google AI) documentation. Use when adding or updating Gemini models in SettingsConfiguration, TranscriptionModels, or TTS config, or when the user asks where to find model names or documentation URLs.
---

# Gemini Model Documentation URLs

Use this skill when you need the **current official model IDs** for Gemini (transcription, prompt mode, TTS) or when checking **GA vs Preview** status. The app uses the **Gemini API** (`generativelanguage.googleapis.com`), i.e. [Google AI for Developers](https://ai.google.dev/gemini-api/docs), **not** Vertex AI.

## Where to find model IDs

### Gemini API – Models (transcription / prompt mode)

**Primary documentation** (same API as the app):

- **Docs – Models**: https://ai.google.dev/gemini-api/docs/models  
- **API reference – Models**: https://ai.google.dev/api/models  

Use these pages to get the **model ID** (e.g. `gemini-2.5-flash`, `gemini-3-flash-preview`) and availability (GA vs preview). Prefer stable/GA IDs over dated preview IDs (e.g. `gemini-2.5-flash-preview-09-2025`) when a GA ID exists.

**Programmatic list**: The API exposes all available models at:

```
GET https://generativelanguage.googleapis.com/v1beta/models
```

Use this to verify current IDs and capabilities at runtime if needed.

### TTS (Read Aloud)

TTS model IDs for the Gemini API are documented here:

- **Speech generation (TTS)**: https://ai.google.dev/gemini-api/docs/speech-generation  

You’ll find IDs such as `gemini-2.5-flash-tts` and `gemini-2.5-pro-tts`. The same base URL is referenced in code (e.g. `TranscriptionModels.swift`).

**Optional**: [Cloud Text-to-Speech – Gemini TTS](https://cloud.google.com/text-to-speech/docs/gemini-tts) documents the same/similar TTS models for Cloud/Vertex; use for cross-check only.

## How to use in this repo

1. **Confirm ID and status**: Open the Gemini API doc URL (ai.google.dev) for the model or the models overview, and read the **model ID** and GA/preview status.
2. **Update code**: Set raw values and `apiEndpoint` in `TranscriptionModels.swift`, `SettingsConfiguration.swift` (PromptModel, TTSModel), and any defaults so they use the current GA or preview ID as appropriate.
3. **Comments**: Keep or add comments that point to the Gemini API doc (e.g. “Current Gemini model IDs: https://ai.google.dev/gemini-api/docs/models”).
4. **Rebuild**: After changes, run `bash scripts/rebuild-and-restart.sh`.

## Quick reference – code locations

- **Transcription / prompt models**: `WhisperShortcut/TranscriptionModels.swift`, `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift` (PromptModel).
- **TTS models**: `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift` (TTSModel).
- **Endpoints**: `TranscriptionModel.apiEndpoint`, `TTSModel.apiEndpoint`; base is `https://generativelanguage.googleapis.com/v1beta/models/{model-id}:generateContent`.

## Google AI Developers Forum

For **Gemini model** topics (IDs, deprecations, outages, TTS/API errors), also check the forum. It often has the first reports of issues and official follow-ups:

- **Gemini API category**: https://discuss.ai.google.dev/c/gemini-api/4  

Useful when: debugging unexplained API/429/500 errors, checking if a model was deprecated or renamed, or before changing model IDs based only on docs.
