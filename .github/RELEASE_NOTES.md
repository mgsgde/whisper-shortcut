# WhisperShortcut 7.33

## What's new
- **Settings sidebar reorder.** Read Aloud now sits above Chat, matching the menu-bar order (Dictate ⌘1 → Dictate Prompt ⌘2 → Read Aloud ⌘4 → Chat ⌥Space). Before, Chat was wedged between Dictate Prompt and Read Aloud, which read inconsistent next to the menu.
- **Review prompt no longer steals focus.** When you've used the app enough to be asked for a rating, it now waits for you to open the menu bar instead of popping up mid-dictation. App Store builds use the native macOS rating prompt; GitHub builds show a one-time "support me on the App Store" note after enough successful operations.

## Fixes
- Cleared the "or the Meeting shortcut" hint from the Chat settings tab — there is no such shortcut; live meetings are started via `/meeting` in chat.

## Behind the scenes
- Three-cycle code-review pass over the most-changed files: consolidated three near-identical `loadPromptModel` helpers into a single canonical one, simplified the shortcut-recorder success path, dropped an unused `ShortcutDefinition.isConflicting`, and reused the new `currentChunkContext` helper in `chunkingStarted`.
- Reset the review-prompt counter on app-version bumps so users get re-asked after meaningful updates.
- Docs refreshed (README, install.sh, in-app text): OpenAI is now mentioned alongside Gemini and Grok, the Read Aloud description matches actual behavior (selection capture + Smart Rewrite + speed control), the slash-commands list adds `/pin` and `/unpin`, and stale shortcut hints (`⌘⌥R`, "Meeting shortcut") are gone.
- `/review-code` slash command rewritten: drops flags in favor of two simple forms (`/review-code` for one pass, `/review-code N` for N review→fix→rebuild cycles); explicitly equal-weighted on bugs *and* simplification opportunities; iteration mode now aborts on a failed rebuild instead of advancing on broken state. LLM-context tooling only — no user-facing effect.

## Installation
Download the latest `.dmg` from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Full changelog

[Compare v7.32…v7.33](https://github.com/mgsgde/whisper-shortcut/compare/v7.32...v7.33)
