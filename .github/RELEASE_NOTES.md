# WhisperShortcut 7.91

The chat can now read files from folders you share with it, and you can change how Dictate Prompt behaves just by asking — no trip to Settings. Plus a fix for dictation corrections that quietly cancelled themselves out.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 📂 Share folders with the chat

- **Workspace Folders** — share folders from your Mac and the chat can list, open, and search the text files inside them. Read-only, and nothing outside the folders you pick is reachable.
- Share a folder from wherever you happen to be: the new **`/folder`** command, the folder button next to `/attach`, by **dropping a folder onto the chat window**, or in Settings → Chat → Workspace Folders.
- **Folder Map** — as the chat discovers how your folders are organized ("journal entries live in ~/Notes/Journal, one file per day"), it writes that down and remembers it in later conversations, so it knows where to look instead of searching again. You can review, correct, or clear these notes in Settings.

### 🗣️ Change Dictate Prompt by asking

- Tell the chat a lasting preference about how Dictate Prompt should rewrite your text — "when I say correct, never translate", "always keep my bullet points" — and it edits the instructions for you.
- It reads the existing rules first and replaces a conflicting one instead of stacking a second rule on top, so your instructions don't slowly contradict themselves.
- The prompt editors for Dictate Prompt and the glossary now offer an **Open Chat** shortcut for exactly this.

### 🐛 Fixes

- **Dictation corrections now stick.** Correcting a misheard name in chat ("Kimmi is written Kimi") had no effect when the misspelling was already in your glossary — both spellings were being sent to the speech model, so they cancelled each other out. Corrections now remove the competing spelling, and glossaries already in this state repair themselves on the next dictation.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.90...v7.91
