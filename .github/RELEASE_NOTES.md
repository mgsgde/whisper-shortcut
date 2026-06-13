# WhisperShortcut 7.63

A chat & meeting interface refresh, plus important fixes to live meeting transcripts.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Redesigned chat & meeting sidebar
- The sidebar now has dedicated **Chats** and **Meetings** sections, each grouped by date (Today, Yesterday, …) with an Archived bucket.
- A single search field searches across both chats and meetings.

### Refreshed dark theme & readability
- New deep-blue (navy) conversation pane against a near-black sidebar and top bar, inspired by modern editor themes.
- Tuned reading typography: a more comfortable line length, clearer spacing between list items (with hanging indents), tighter paragraph rhythm, and a touch of letter spacing that keeps text crisp on dark backgrounds.
- Your own message bubbles now match the input field and are **selectable**.
- Quieter, ChatGPT-style action buttons (Copy, Retry, Read Aloud) — icon-only with a subtle hover.

### Smarter titles
- AI-generated chat and meeting titles now begin with a fitting **emoji** for quicker scanning.

### Live meeting fixes
- **Each meeting shows its own transcript** — meeting tabs no longer all display the currently-recording meeting.
- **Resuming a meeting now truly continues it**: the existing transcript and summary are restored and new content is appended to the same recording (previously the transcript could be wiped).
- The meeting that is **currently recording is marked with a red dot** in the sidebar, so you can see at a glance which one is active.
- The loading indicator is now aligned with the conversation column instead of drifting to the bottom-left.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.62...v7.63
