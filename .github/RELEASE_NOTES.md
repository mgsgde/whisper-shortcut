# WhisperShortcut 7.47

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Your Glossary now works with every transcription model

- **The vocabulary Glossary now improves cloud transcription too** — not just offline Whisper. The hard-to-spell names, jargon, and product names you list are sent to Gemini, OpenAI Transcribe, and xAI Grok as well, so they get spelled right far more often.
- Clearer Speech-to-Text settings: the section is now simply called **Glossary**, and the labels explain the split — the *system prompt* controls *how* to transcribe (filler words, punctuation, formatting), while the *Glossary* holds the *terms* to get right.

### More reliable titles and suggestions

- **Chat titles and "Improve from usage" suggestions are more robust.** They now use each provider's structured (JSON) output instead of parsing free-form text, so there are fewer malformed or empty results — on Gemini, OpenAI, and xAI alike.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.46...v7.47
