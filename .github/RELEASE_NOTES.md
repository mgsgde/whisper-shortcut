**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

A maintenance release: safer chat tools and steadier Read Aloud.

## Chat tools
- Chat now asks before it remembers a file location or a dictation term. Two new approval cards show what would be stored.
- Fixing a transcript term replaces whole words only, so correcting "Ana" to "Anna" no longer changes "Banana".
- Forgetting facts about you needs a real search term, so a single letter cannot wipe your memory.
- Edit approvals show the same "overwrite" and "all occurrences" choice the tool then carries out.
- Reading a long text file no longer garbles non-ASCII characters at the cut-off, and very large files are checked before they are loaded.

## Read Aloud
- Read Aloud no longer hangs when the audio output changes, for example when AirPods connect.
- A synthesis that produces no audio ends cleanly instead of leaving the app busy.
- After Read Aloud on a selection, your clipboard is restored (same "restore clipboard" setting as Dictate).

## Mail and Chat
- Forwarded mails are read, with sender and subject of the forwarded message.
- Mails written in HTML keep their paragraph breaks.
- Clearing a chat also clears its error banner.

## Settings and onboarding
- "API Keys & Endpoints…" and the missing-key hint open Settings directly on Accounts.
- The OpenRouter model field stays visible while you type.
- In the welcome tour, picking Cloud before pasting a key now switches Dictate to the cloud once the key is there.

## Screenshots
- Dictate Prompt screenshots capture the display with the frontmost window.
- A screenshot folder on an unplugged drive keeps its setting.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.55...v8.56
