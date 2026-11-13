## Screen context only with your consent
- **Dictate Prompt no longer reads your screen unless you allow it.** The text around the cursor and the picture of the front window are now separate switches, both off by default, also for existing users. Turning one on asks for your consent first. Selected text is still sent as before.
- **Names from the text field (optional).** Plain Dictate with GPT Transcribe can send capitalised names from the field you type in as spelling hints. Off by default, under Dictate → Advanced.

## Read Aloud
- **Keyboard controls while reading:** Space pauses and resumes, the arrow keys skip 10 seconds, Esc stops.
- **New shortcut Read Aloud Prompt (⌃⌥⇧4)** speaks the Dictate Prompt result instead of pasting it (direct download only).
- Qwen3 voices buffer ahead instead of pausing after every sentence.

## Dictation
- Background noise and long pauses are no longer sent to the cloud, so they stop coming back as Glossary words.
- Dictate Live inserts text at pauses even in a room with some background noise, keeps a spoken colon, and writes quantities as digits ("140 zu 90", "GdB 50").
- Dictate Prompt no longer pastes Gemini's own thinking or planning notes.
- The ⌘2 card shows your three most-used prompts, no scrolling.
- Long recordings that were already transcribed while recording no longer ask what to do.
- Freeing the Globe key for dictation now takes effect immediately.

## Chat
- Revised default prompts for Chat and Dictate Prompt. If you never changed them, you get the new ones.
- The Chat follows new text as it arrives.
- Calendar events and tasks are created right away when title and time are clear. Events with guests, changes and deletions still ask first.
- If Google, Trello or mail is not connected, the Chat says so and links to Settings.
- New model GPT-6.1 Terra.

## Settings and AI apps
- Connected AI apps (Claude Code, Claude Desktop, Codex) reconnect on their own when their access token went stale, and can see which helpful features are switched off.
- Short hints for the Fn/🌐 key and Accessibility; the Dictate Prompt tab names the speech recognition and Glossary it uses.
- A one-time notice when screenshot saving is on but no folder is set.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.90...v8.91
