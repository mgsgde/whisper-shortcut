# WhisperShortcut 7.34

## What's new
- **Privacy & permissions onboarding.** A new welcome flow walks you through the permissions WhisperShortcut needs — microphone, accessibility, and (for screenshots) screen recording — and explains the optional Smart Improvement step. A dedicated Privacy & Permissions tab in Settings shows the live status of each permission at a glance, and the privacy policy is now linked from a hosted page.
- **Save screenshots to a folder.** A new Screenshot settings tab lets you keep every capture in a folder of your choice (in addition to the clipboard). The new `/attach` chat command pulls a file straight into the composer.
- **Smarter chat sidebar.** Search your chats, jump to a dedicated Meetings section, and let older conversations archive automatically so the list stays tidy. Renaming chats is more reliable, and meeting chats are now titled from their summary instead of the first thing you said.

## Fixes
- Clicking an attachment chip in the chat composer now reliably opens its preview — including clicks that land on the right half of the chip — and no longer fires when you click the empty input area beside it.
- The chat window no longer closes itself (and orphans the screenshot preview sheet) when a sheet takes focus.

## Performance
- Chat rendering is noticeably faster: parsed message content is memoized, so switching chats and re-rendering long conversations no longer re-parses everything on the main thread.

## Behind the scenes
- Three-cycle code-review pass over the most-changed files: removed dead attachment-removal helpers and a redundant config read, deduplicated the composer's attachment counters, consolidated the synthetic ⌘C / ⌘V key simulation into a single helper (and fixed a misleading `simulateCopyPaste` name that only copied), and trimmed stale comments and leftover perf logging.

## Installation
Download the latest `.dmg` from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Full changelog

[Compare v7.33…v7.34](https://github.com/mgsgde/whisper-shortcut/compare/v7.33...v7.34)
