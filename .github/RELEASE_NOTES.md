**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Updates
- **Stable and Latest update channels.** Settings → About now lets you choose how fast updates arrive. **Stable** (the default) gets a new version only after it has run in daily use for about a week. **Latest** gets every release on the day it ships. This release is the first on the Latest channel, so Stable users will see it a little later.

## Meetings
- **The Listening indicator stays on top.** During a meeting it no longer slips behind the meeting window or WhisperShortcut's own Chat.
- **Cleaner Mac sound with Bluetooth earbuds in call mode.** Audio from the other side is now resampled smoothly instead of with gaps, for more accurate transcripts.

## Chat and Dictate Prompt
- **Failed replies say so.** When an OpenAI or Grok reply fails mid-stream, Chat shows an error instead of an empty bubble, and a reply cut off at the length limit shows the truncation hint.
- **Dictate Prompt replies are no longer cut.** A reply that ends in a phrase such as "remove filler words", or mentions your prompt's keywords, is kept in full.
- **Chat never opens credential folders.** Its file tools refuse `.ssh`, `.gnupg`, `.aws`, `.kube` and `.docker`, even through symlinks.

## Settings
- **Smart Improvement is one switch.** Turn on "Learn from how I use WhisperShortcut" and it learns your writing style and improves itself every 7 days. The detailed controls are under Details.
- **Settings opens larger**, at most of your screen height instead of a fixed small window.
- **Read Aloud reads numbers as written**, so "1000000" is no longer shortened.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.70...v8.71
