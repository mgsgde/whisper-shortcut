**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Offline dictation
- **Parakeet Ultra (Offline)** is the new recommended on-device dictation model for the 25 languages it covers. It is about as accurate as Whisper Large v3 Turbo and returns text in a fraction of the time — around 0.1 s for a short sentence instead of about 2 s. Download size is about 700 MB. For other languages Whisper Large v3 Turbo stays recommended.
- Your **Glossary** also works with Parakeet Ultra, as a vocabulary for names and technical terms ("Whisper Glossary" is now just "Glossary").
- Onboarding without an API key and turning on Offline Mode without a downloaded model now offer Parakeet Ultra. **Your current model selection is never changed.**
- The download progress bar moves all the way to 100 %.
- Settings → About lists the open models the app uses, with their licenses.

## Privacy
- **Offline Mode now makes no network request at all.** A local chat model that is already downloaded loads straight from disk; before, every load asked Hugging Face for the model's file list.
- **Your content no longer appears in the app's log files.** Transcripts, selected text, chat replies, tool results, glossary terms and prompt previews are logged only by their length.
- **Anonymous usage statistics (opt-in, off by default).** A new switch in onboarding and Settings → Privacy & Permissions sends a daily summary of counts — which features were used and whether they worked, failure classes, which built-in models ran — if you turn it on. Never transcripts, prompts, replies, audio, the apps you paste into, or any identifier. "See exactly what is sent" shows the exact data; turning it off deletes anything queued. Unavailable in Offline Mode. The server code is public in `server/telemetry/`.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.27...v8.28
