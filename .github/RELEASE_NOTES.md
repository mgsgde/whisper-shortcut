# WhisperShortcut 7.96

Meetings now take notes into the chat while they happen, the chat can answer questions about anything said since the meeting started, and dictation finally has accuracy controls — including a fix for a setting that was quietly working against you.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 🎙️ Live Meeting

- **Live notes appear in the chat itself.** Every minute or two the app appends a line or two about what was just discussed, woven into the conversation at the moment it was said — so you can see what is going on in the same column you type in. Earlier notes are never rewritten.
- **The chat sees the whole meeting.** Previously it only knew a summary plus the last five minutes, so asking "what did we decide about X earlier?" during a long meeting didn't work. Now the full transcript goes with every question, and a line above the composer tells you exactly what the chat can currently see.
- **One-tap questions** above the composer: Catch me up, Action items, Open questions, Decisions.
- **Ask about a moment**: hover any note and press *Ask* to quote it into the composer instead of retyping what was said.
- **Flag a moment** with a new shortcut (⌘6 by default). You can't type during a meeting, so press it when something matters — flagged moments show up in the notes, and the final summary is written around them.
- **Two tabs instead of three**: Chat and Notes, plus a **Copy transcript** button. The transcript is something you paste elsewhere, not something you read in the app (right-click the button to reveal the file in Finder).
- **The live view keeps up.** Audio chunks rotate every 25 seconds while the chat window is open, instead of trailing the room by up to a minute, and fall back to your configured interval when it isn't.
- A meeting whose summary failed to generate now retries when you open it, instead of sitting there with nothing.

### 🎤 Dictation accuracy

- **Temperature is now yours to set — and no longer 1.0.** The app never sent this value, so every cloud transcription ran at the model's own default of 1.0: full creative sampling for a task whose entire job is to reproduce what you said. It is the most likely source of invented or swapped words. The new default is **0.0 (verbatim)**, adjustable in Settings → Dictate.
- **Thinking effort** (Gemini) is configurable instead of hardcoded to the lowest level. Raising it can help with difficult audio, accents, and unusual vocabulary; on Flash-Lite it costs almost no extra time. The default is unchanged, so nothing gets slower unless you ask for it.
- Models that start their answer with "Here is the transcription…" no longer paste that preamble into your document.

### 🔀 OpenRouter

- **Dictate through any audio-capable model on OpenRouter** with a single API key. Pick the model slug in Settings → Dictate and switch between providers without a new setup. Because OpenRouter has no dedicated transcription endpoint, your Dictation system prompt and Glossary apply here — unlike the OpenAI and self-hosted transcription endpoints.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.95...v7.96
