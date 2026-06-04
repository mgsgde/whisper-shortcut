# WhisperShortcut 7.50

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Chat with generated images: cleaner and faster

- **Copying a whole chat no longer includes raw image data** — generated images are replaced with a short placeholder in every copy, search, and read-aloud flow.
- **Smoother streaming after an image is generated** — decoded images are cached, so the reply text streams without re-decoding the image on every word.
- **Read Aloud skips generated images** instead of announcing them.

### Chat reliability

- **Queued messages stay in their chat** — sending a follow-up while a reply is streaming and then switching tabs no longer delivers the queued message to the wrong conversation.
- **Stopped replies survive a restart** — pressing Stop mid-reply now saves the partial text, so it's still there after quitting and relaunching.
- **`/model image`-style commands** resolve directly to the image model (Flash tier) instead of asking you to disambiguate.

### Under the hood

- **Faster failure on Gemini server errors** — the retry logic no longer waits through a pointless final 32-second backoff, and extended retries for 500/503 errors now actually run.
- **Shared connection pool** for all Gemini requests (chat, transcription, analysis) instead of separate ones per component.
- Removed ~190 lines of dead and duplicated code (unused views, identity helpers, duplicated error mapping, leftover debug logging).

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.49...v7.50
