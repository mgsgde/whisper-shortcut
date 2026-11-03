## Security
- **Your keys stay where they belong.** Your OpenAI key and own-server tokens are no longer sent to plain-http hosts on your network (localhost still works), and they are dropped when a server redirects elsewhere. The same now applies to meeting transcription.
- **Safer links in Chat.** Links in Chat replies open only for http, https and mailto. file:// and custom-scheme links do nothing.
- Mail, Tasks and Trello error logs no longer contain titles, instructions or Trello keys.
- A crafted, deeply nested email can no longer freeze or crash the app.

## Offline dictation
- **"Only when spoken" keeps sentence marks.** Periods, question marks, exclamation marks and colons the model sets now stay; only its commas and semicolons are removed. Spoken punctuation works as before.
- **Glossary is more careful.** The offline model no longer drops lab values such as "HbA1c 7,2" or swaps one glossary drug for another, and glossary casing is kept ("GdB 50").
- "…schrägstrich" and "3-Pünktchen" are converted even when the model glues them to the previous word.

## New: Services menu
Select text in any app, right-click → Services: **Read Aloud with WhisperShortcut**, **Add to WhisperShortcut Glossary** and **Dictate Prompt with WhisperShortcut**. No Accessibility permission needed.

## Chat
- Replies keep their line breaks. "$5", `$HOME` and Windows paths like C:\Users\… are shown as written; real math still renders.
- Claude no longer fails with an error on the last tool round.
- Chat with OpenAI, Anthropic, xAI and others retries automatically when the provider is briefly rate-limited.
- Empty replies left behind by quitting mid-answer are repaired; pasted HEIC/TIFF images are converted; search and auto-title fixes.
- A local server without a key is shown as ready.

## Meetings
- Text that finishes transcribing after a meeting ends lands in that meeting, in speaking order, not in the next one.
- A second press of the meeting shortcut while a segment is processing no longer ends the meeting.
- A second Stop while a meeting is finishing no longer hangs.

## Fixes
- **Reset in Settings deletes all private data** (downloaded models and workspace backups stay). Stored audio samples expire after 30 days.
- Read Aloud ends cleanly after an error mid-sentence.
- A glossary term Chat adds while the glossary editor is open is no longer overwritten.
- Clearer status and error texts ("Dictate Prompt", "Read Aloud", "Invalid API Key" → Settings → Accounts).
- Clearer Gemini errors for subscription required and rate limits.
- API key fields save once per typing pause.
- Calendar events switch correctly between timed and all-day; MCP meeting lists no longer hang while a dialog is open.
- The direct download no longer asks you to rate or buy on the App Store.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.77...v8.78
