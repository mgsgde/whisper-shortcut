# WhisperShortcut 7.94

Brings **X search back to Grok** — now narrowed to the accounts you trust — plus a calmer chat queue and a real fix for cancelled Dictate Prompts.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 𝕏 Grok searches X.com again

- **X search is back on for Grok models.** It was dropped once for latency, but its bias toward opinion over fact is exactly the point — reading what people on X actually say is the main reason to pick Grok over Gemini or GPT. xAI runs web and X search side by side and decides per question, so the extra tool only costs a round trip when X is genuinely worth searching.
- **New `/x` command — restrict it to accounts you trust.** `/x @karpathy @simonw` limits X search to those accounts for the current chat; `/x off` searches all of X again. Set a default under Settings → Chat.

### 💬 Chat

- **Messages sent mid-reply are queued instead of discarded.** Previously a second message replaced the one still generating. Now each is answered in turn, so you can fire off several thoughts in a row without losing an answer.

### 🎤 Dictate Prompt

- **Cancelling now actually cancels.** Stopping a Dictate Prompt while it was still working left the reply in flight — and it would paste itself into whatever you had focused by the time it arrived. It is now dropped, and the cancelled recording is cleaned up instead of being left on disk.

### 🧹 Under the hood

- Live meeting recording moved into its own `LiveMeetingSession` type: the transcript file, chunk pipeline, and rolling-summary policy now have a single owner instead of 17 loose flags on the menu-bar controller.
- Dictate and Dictate Prompt share one completion pipeline, so cancellation, staleness, and cleanup can no longer drift apart between them.
- Chat tools dispatch through one registry entry point, and the OpenAI-compatible providers share their request-shape helpers instead of carrying five hand-written copies.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.93...v7.94
