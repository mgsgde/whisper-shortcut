## Dictation
- **Spoken slash between numbers:** in Dictate Live with punctuation set to "Only when spoken", "sechs Schrägstrich fünfundzwanzig" now becomes "6/25" instead of "6-25", for dates, file numbers or "LWK 4/5".
- Fixed: pressing Fn and another key very quickly could leave dictation stuck until the app was restarted.

## Chat
- **Improve:** click Improve in an empty chat or type `/improve`. The Chat reviews your settings, permissions, models and (with "Save usage data" on) your recent dictations, and suggests one change at a time that you approve. It runs on a strong model for the review only; a chip "Improve: <model> ✕" next to the model picker lets you switch or end it.
- A prompt with nothing selected now says so instead of making up content.

## Read Aloud
- Return and Enter pause and resume, like Space. The arrow keys skip 5 seconds; the ⏪/⏩ buttons still skip 10.
- Pausing no longer loses keyboard control, so a second Return resumes.

## Writing Style
- Suggestions for your writing style profile no longer pop up in a window. A dot on the menu bar icon and "Review Writing Style Suggestion…" in the menu show them, at most once every 14 days. Each change lists the quotes from your own messages that back it.

## Other
- The recording pill now also shows over apps in full screen.
- Retired models: gpt-4o-transcribe is no longer offered (GPT Transcribe takes over). OpenAI's Read Aloud voice gpt-4o-mini-tts, which OpenAI shuts down in January 2027, is replaced by Gemini 3.8 Flash-Lite TTS if you have a Gemini key, otherwise by the macOS voice.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.92...v8.93
