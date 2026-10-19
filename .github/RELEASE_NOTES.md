**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Dictate Prompt
- **Follows your writing style from memory.** Style facts you told Chat to remember, such as "only short hyphens" or "keep it short and natural", now also shape Dictate Prompt replies (cloud models only). If you asked for short hyphens, long dashes are replaced in the output.
- **Pastes only where you started.** The result goes into the app that was in front when you started recording. If you switched apps in the meantime, it stays on the clipboard and you see "Copied – press ⌘V to paste" (direct-download build).
- **No more parallel runs.** Starting again while a run is busy shows "Busy – wait for the current run to finish."
- An empty model reply is now a retryable error, and your recording is kept. Replies that were cut off show a notice.
- A long dictation can now be cancelled while it is processed in parts.
- Offline Mode no longer saves Dictate Prompt runs to history.

## System prompts are never lost silently
- Prompt editors save automatically while you type, so the Save button is gone. A status shows "Saved", "Saving…" or "Not saved".
- If your saved prompts can't be read (for example missing Full Disk Access), the app tells you at launch and never overwrites them. Customized prompts get a backup (`system-prompts.md.bak`) before every change.

## Smart Improvement
- **Scorecard.** Settings → Smart Improvement shows whether an accepted change helped: rejected spellings, follow-up fixes, dashes added and retries, week by week and since the last change. The review window shows what was measured so far. Everything is counted on your Mac.

## Other
- Meeting notes and summaries wait as long as the server asks when they hit a rate limit.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.44...v8.45
