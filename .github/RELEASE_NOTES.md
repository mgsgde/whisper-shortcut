# WhisperShortcut 7.53

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Chat

- **Smoother message list.** Sending a message or resizing the chat window no longer briefly clears the visible message list. A redundant layout workaround that forced the list to rebuild on every width change has been removed.

### Meeting summaries & titles

- **More reliable meeting titles.** Title generation now retries on temporary provider errors (e.g. HTTP 503), so a brief API hiccup during recovery is less likely to leave a meeting stuck with a generic "Meeting" name.
- **Cleaner summary pipeline.** Consolidated duplicate meeting-summary helpers and improved logging when credentials are missing.

### Under the hood

- Chat view model cleanup: removed unnecessary main-thread hops and replaced a scroll-anchor counter hack with a clearer signal.
- Added live LLM provider roundtrip tests (Gemini, OpenAI, Grok) for development — each skips cleanly when its API key is not configured.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.52...v7.53
