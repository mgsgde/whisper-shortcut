# WhisperShortcut 7.62

A Settings redesign focused on clarity, plus live API‑key verification.

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### API keys you can trust at a glance

- Each API‑key field now shows a live status badge: **Connected**, **Invalid key**, **Checking…**, or **Unverified**.
- The key is verified directly with the provider (Google, OpenAI, xAI), so a typo or expired key is caught immediately instead of failing later mid‑transcription. Being offline never falsely flags a good key.

### Clearer, calmer Settings

- **Model pickers are now grouped.** Transcription models are split into **Cloud** (needs an API key) and **Offline** (runs on your Mac); chat models are grouped by provider, with image‑generation models in their own section.
- **Recommended models** are marked with a star right on the tile, and tiles highlight on hover.
- **The General tab was split** into focused tabs: **General** (API keys + behavior), **Smart Improvement**, and **About** — which also includes a one‑glance overview of every keyboard shortcut.
- **Native icons** replace emoji throughout Settings for a cleaner, more Mac‑like look.
- The Settings window **no longer closes when it loses focus** by default (you can switch this back on).

### Fixes

- Smart Improvement and Meeting Summary no longer offer models that can't do the job (audio‑only or image‑generation models).
- Reliability fixes for usage‑based improvements and interaction logging (live‑summary safeguards, calendar error hints, hang capture, and Markdown rendering).

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.61...v7.62
