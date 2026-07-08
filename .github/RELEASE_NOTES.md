# WhisperShortcut 7.80

Meeting summaries got cheaper and faster, and the new instant glossary learning was polished.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 💰 Cheaper, faster meeting summaries

- The speaker-labeling consolidation pass is now skipped entirely when a meeting has only one speaker — nothing to reconcile, so the whole (paid) step disappears.
- When it does run, it uses the cheapest suitable model of your provider instead of the full summary model: the pass only relabels speakers, but it echoes the entire transcript back, so output-token price dominates its cost.

### 📖 Glossary learning polish

- Typing the same term in different casings within one message ("Grok" and "GROK!!!") no longer produces duplicate glossary entries.

### Other changes

- README: leads with a 30-second pitch and the demo GIF; license note updated to AGPL-3.0.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.79...v7.80
