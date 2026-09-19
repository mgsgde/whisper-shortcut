**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Read Aloud
- **Gemini voices start about six times faster.** Gemini TTS audio is now streamed into playback as it arrives, and every chunk is synthesized in parallel. On a 2,000-character selection the first sound came after 0.96 s instead of 6.5 s, with the whole text ready in under 10 s.
- **Playback no longer starves.** Chunk sizes ramp up from short to long so the next piece of audio is always ready before the current one ends. If the queue does run dry, the player pill shows a spinner and "Loading…" instead of going silent without explanation.
- **Stalled synthesis is cut off and retried.** A Gemini stream that stops delivering audio is aborted and requested again, so one hung request no longer holds up the rest of the text.

## Chat
- Gemini chat replies now arrive over a true server-sent-event stream. The `alt=sse` request parameter had been dropped when the API key was appended to the URL, so responses were streamed in a heavier JSON-array format instead.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.18...v8.19
