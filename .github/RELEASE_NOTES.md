# WhisperShortcut 7.99

**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

Prefer a direct download? Grab the signed `.dmg` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

- **Dictation no longer freezes on a stalled request.** A transcription that stopped responding could sit for minutes with the menu bar stuck on "transcribing", and the only way out was to notice it and cancel by hand. It now fails after 60 seconds with a clear "Request Timeout" message, keeps your audio, and offers a retry.
- **A dismissed review window no longer locks the app.** Closing the Smart Improvement / Voice Feedback proposal window with the red button, Escape or ⌘W left the app unresponsive with nothing on screen. Dismissing it now simply counts as "not now".
- **Voice Feedback reads your selection.** Select a name, press the shortcut and say "remember how this is spelled" — the glossary now takes the spelling from your selection instead of from how the transcription heard it, which is what makes teaching a spelling by voice work at all.
- **A stray Fn keypress can no longer discard a finished dictation.**
- **Every model response is capped**, so a thinking model cannot spend your API budget without ever answering.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.98...v7.99
