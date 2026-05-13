# WhisperShortcut 7.15

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Added

- **Copy a full chat as Markdown**: Use the new `/copy` slash command in the chat composer, or right-click any chat in the sidebar and choose **Copy chat**. The entire conversation lands on the clipboard as Markdown — ready to paste into a doc, email, or issue.
- **Chat now knows its own commands**: When you ask the chat "what commands exist?", it answers with the exact set of slash commands available in this build (`/new`, `/screenshot`, `/copy`, `/connect-google`, `/connect-trello`, `/pin`, `/meeting`, …) instead of guessing from training memory.

### Changed

- **Reordered composer toolbar**: The buttons under the chat composer now follow a more natural order — **Attach · Screenshot · New chat · Meeting**.
- **More screenshots per message**: You can attach up to **10** screenshots to a single chat message (was 5).
- **Smarter send-while-busy**: Sending a new message while one is still streaming now *replaces* the in-flight request instead of queueing behind it. No more surprise extra responses if you change your mind mid-stream.

### Fixed

- **Clearer xAI (Grok) errors when credits run out**: An xAI account that is out of credits or has hit its monthly spending limit now produces a direct, actionable message ("top up or raise the limit at console.x.ai") instead of a generic rate-limit notice that just tells you to wait.

## Full changelog

[Compare v7.14…v7.15](https://github.com/mgsgde/whisper-shortcut/compare/v7.14...v7.15)
