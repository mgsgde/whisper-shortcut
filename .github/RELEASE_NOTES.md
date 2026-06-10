# WhisperShortcut 7.52

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Meeting summaries & titles

- **Meeting summaries now work with every provider.** Previously, if your selected meeting-summary model was an OpenAI or xAI (Grok) model, the summary, rolling summary, and speaker consolidation were still sent to Google's Gemini endpoint and failed — leaving the meeting with no summary and a poorly chosen title. These now route to whichever provider owns the selected model (Gemini, OpenAI, or Grok).
- **Automatic summary recovery.** If a meeting ended without a summary, opening its Summary tab now regenerates it on the spot and derives a proper title from it.
- **More reliable meeting titles.** Titles are applied directly to the open meeting, fixing cases where a title silently failed to attach and the meeting stayed on its first-message fallback name.

### Stability

- **Transient-error retry for summaries.** Summary generation now retries on temporary server errors (e.g. HTTP 503) with backoff, so a brief provider hiccup no longer permanently loses a summary.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.51...v7.52
