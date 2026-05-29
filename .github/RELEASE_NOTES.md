# WhisperShortcut 7.37

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Switch chat models in a keystroke

Changing the chat model used to mean typing the full `/model gemini 3 flash`. Now every model has its own short slash command, and the picker is fully keyboard-driven:

- **One command per model** — `/gemini`, `/grok`, `/gpt` switch to each provider's default, and readable per-model commands like `/gemini3flash`, `/gemini25pro`, or `/grok4` jump straight to a specific variant. Type `/gem` to see all Gemini variants at once.
- **Arrow-key navigation** — use ↑/↓ to move through the suggestion list and **Enter** to pick (Tab still works too). Long lists scroll to keep the highlighted row in view.
- **Most-recently-used ordering** — your recently used models float to the top, and the model you're already on is hidden, so the top suggestion is always a one-Enter toggle back to your previous model.

### Reliability

- Fixed chat creating duplicate Calendar events and Trello cards in some cases; tool-call arguments and results are now logged for easier debugging.
- Smart Improvement now acts on a pattern after 2 distinct interactions instead of 3, so suggestions surface sooner.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.36...v7.37
