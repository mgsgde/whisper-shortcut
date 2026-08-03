# WhisperShortcut 7.98

Chat can watch a YouTube video now, and you can hand the developer a picture of how the app actually behaved for you — without handing over anything you said.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 📺 YouTube videos in chat

Paste a YouTube link and a Gemini model actually watches the video, instead of guessing from whatever the web says about it.

- **Link a moment and it looks there.** Add a timestamp (`&t=1h50m10s`) and the model analyses a ten-minute window around it — the sensible way to ask about one passage of a two-hour podcast.
- **Without a timestamp the whole video is sent.** If it is too long for the model, the opening ten minutes are used and the answer says so, rather than quietly answering about the wrong part.
- **Gemini only.** Other providers cannot open YouTube links, and the app tells you instead of failing obscurely.

### 📊 Share Usage Report

A **Share Usage Report** button in Settings → About summarises how the app has actually been working for you: how many dictations and chats, which models, how often a result had to be redone.

It contains **no transcripts, prompts, replies, or audio** — only counts and model names — and the full text is shown to you before anything is sent. Nothing leaves your Mac until you press send.

### 🐛 Fixes

- **Dictate Prompt no longer pastes raw JSON into your document.** The audio model sometimes answers an editing instruction with its internal edit format instead of the edited text. When that format could not be applied, the entire `{"edits": [...]}` string replaced whatever you had selected. Now the selection is left untouched — a failed edit does nothing, instead of destroying the text.
- **Gemini 3.1 Pro is no longer offered for dictation.** Measured against a 1.3-second recording it returns no response at all — four attempts in a row, one of which waited five minutes for zero bytes — while a control request answered in about six seconds. Rewording the prompt does not help and neither does streaming, so there is nothing to fix on our side. If you had it selected, dictation moves to Gemini 3.1 Flash-Lite automatically. The model stays available for Chat and Dictate Prompt.
- **Starting and stopping a recording no longer blocks the main thread**, so the menu bar stays responsive while audio devices come up.

### 🧹 Under the hood

- Monthly model audit: every shipped model ID re-verified against the live provider APIs. Corrected stale GPT-5.6 pricing notes, documented Gemini 3.1 Flash-Lite's 2027-05-07 shutdown and why we are deliberately not following Google's suggested replacement, and moved the deprecated `gpt-audio-mini` out of the migration-candidate list so a future audit cannot promote it.
- The transcription benchmark now covers the Gemini Pro tier's thinking-level requirements and records why that tier is excluded from dictation.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.97...v7.98
