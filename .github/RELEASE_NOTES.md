# WhisperShortcut 7.11

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Added

- **Trello in chat**: Connect Trello with PKCE OAuth from the chat settings tab. New chat tools let the model list boards, lists, cards, and create cards directly from a chat session.
- **Read Aloud on chat replies**: The Read Aloud button is back next to Copy on assistant messages.

### Improved

- **Smart Improvement audio verification**: The dictation and Whisper Glossary focuses now confirm or reject text-stage suggestions against the original audio. Verification only runs when the Smart Improvement model is strictly stronger than (or a different family from) the model that produced the clip; audio samples are wiped at the end of every run.
- **Tighter Smart Improvement suggestions**: Recommendations now require evidence across multiple distinct interactions, with stricter generality and abstraction filters, so one-off quirks no longer rewrite your prompts.
- **Faster Grok chat**: Dropped `x_search` from Grok's tool list (`web_search` alone is enough) and made the in-flight tool loop cancellation-aware, so stopping a stream or sending a new message aborts immediately instead of running the remaining tool calls.
- **Calendar and Tasks links in replies**: Google Calendar event and Google Tasks responses now include the web link so the chat model can surface it directly in the reply.
- **Read Aloud lifecycle hardening**: A stale playback completion can no longer reset state after the user has moved on, and Read Aloud now declines while another operation is processing instead of stomping the current state.

### Fixed

- **Clear error for non-image Grok attachments**: Attaching a PDF (or any non-image file) to a Grok chat now fails fast with an actionable message pointing to Gemini, instead of a confusing xAI 400 error.

## Full changelog

[Compare v7.10…v7.11](https://github.com/mgsgde/whisper-shortcut/compare/v7.10...v7.11)
