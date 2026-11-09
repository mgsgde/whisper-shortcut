## Privacy and data safety
- **Meetings stay local without a meetings key.** If no key is set for meetings, meeting transcription no longer switches to a cloud model.
- **Chat history is never overwritten.** If the chat store cannot be read, it is left alone instead of being replaced with an empty one.

## Meetings
- Less audio is lost when you quit the app or the recorder fails during a meeting.
- After you resume a meeting, notes and summary are updated again, and new chunks line up with the right time.
- Notes from a resumed meeting are no longer deleted by a later edit.

## Read Aloud
- **Your own server.** Read Aloud can now speak through your own OpenAI-compatible server (Settings → Read Aloud → Own server).
- The last syllable is no longer cut off.
- Qwen3 voices no longer start with a long silence before text that opens with a web address or byline.
- Stereo recordings imported as a reference voice no longer arrive almost silent.

## Chat
- Numbered and nested lists display correctly, and text containing a "|" is no longer shown as a table.
- Undo (⌘Z) works in the message field after pasting a chip and after sending.
- Fixes for Google Tasks (due dates, hidden and long lists), Google Calendar paging and searches containing "+" in Gmail and Trello.
- Chat and AI apps connected over MCP can now tune WhisperShortcut from your usage log on request. The automatic Smart Improvement is removed; its settings moved to Privacy & Permissions and Dictate Prompt.

## Dictation and setup
- The Offline card in onboarding only continues once the offline model has finished downloading.
- Spoken punctuation produces fewer false marks, and Qwen3 dictation uses your glossary.
- Settings explains that your own server ignores the dictation prompt; Check now tests the same address that dictation uses.
- Clipboard: Add to Glossary restores your clipboard, and Glossary and Read Aloud no longer pick up an old clipboard. A VS Code line copy with nothing selected counts as "nothing selected".
- Fixes for the Fn cancel key, the missing-setup icon, the microphone after a cancelled permission prompt, OpenRouter transcription timeouts, the recording pill after display changes and system audio after device changes.
- Connecting Claude Desktop from a copy that is not in Applications is refused with an explanation.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.87...v8.88
