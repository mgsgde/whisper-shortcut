---
name: gemini-model-docs
description: Look up current Gemini model IDs and GA vs Preview status. Use when adding or updating Gemini models in SettingsConfiguration, TranscriptionModels, or TTS config, or when the user asks where to find Gemini model names or documentation URLs. For multi-provider work (OpenAI + Gemini + xAI), use llm-model-docs instead.
---

# Gemini Model Documentation URLs

For full Gemini coverage (URLs, GA/Preview status, programmatic model list, the proactive lineup-check workflow), use the **llm-model-docs** skill — its Gemini section already lists every URL this stub used to duplicate.

This stub exists only to surface Gemini-specific TTS facts that don't fit neatly under the multi-provider skill:

## Gemini TTS specifics

- TTS models live on the **Speech generation** page: <https://ai.google.dev/gemini-api/docs/speech-generation>. Look there for the TTS voice catalogue and the `gemini-2.5-*-preview-tts` style IDs.
- The same TTS base URL is referenced in code from `SettingsConfiguration.swift` (`TTSModel.apiEndpoint`).
- Cloud Text-to-Speech (`cloud.google.com/text-to-speech/docs/gemini-tts`) documents the same/similar TTS models for Cloud/Vertex; use only as a cross-check — this app talks to `generativelanguage.googleapis.com`, not Vertex.

For anything beyond TTS (chat / transcription / programmatic listing / GA flips / outages), read `llm-model-docs` and skip this stub.
