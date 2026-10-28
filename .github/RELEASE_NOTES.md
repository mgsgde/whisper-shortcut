**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Dictation
- **No more glossary words tacked onto the end.** A single glossary name after a long, correct sentence ("… 14 inch notebook. Joschka.") is now removed. A short sentence that really is just a name, like "Viele Grüße. Joschka.", stays.
- **Meetings no longer log your whole glossary as speech.** Near-silent stretches sometimes came back as the full glossary list and ended up in the transcript. Those lines are now dropped.
- **Report a problem with your last dictation.** Send Feedback → Report a Problem with Last Dictation… opens a window with the details filled in (the text you got, mode, model, app and macOS version). Edit it, then send it by WhatsApp or email, or copy it.

## Own server
- **One endpoint for everything.** If you run your own OpenAI-compatible server (LiteLLM, Azure, a self-hosted model), enter one base URL and one key and Dictate, Dictate Prompt and Chat all use it. The picker entry is now called "Own server".
- **Dictate Prompt works with your own server.** It transcribes on the server, then the server's chat model applies your instruction.
- Your existing Dictate server URL is carried over on first launch. A URL that doesn't fit the shared base stays as an override under Advanced.

## Settings
- **Cleaner model pickers.** Tiles no longer say "Offline" twice. A model that isn't downloaded yet shows one "Needs download" badge, and the download list only appears when you need it.
- The Claude & AI Apps tab now says in full what AI apps may change.

## Fixes
- Meetings: a dictation, a pending stop or a recorder error during a meeting no longer throws the meeting's recording state off.
- Chat: no longer gets stuck after a failed API key check, and Regenerate no longer repeats actions you had already approved.
- Your own quick prompts containing words like "short", "todo" or "fix" now run when nothing is selected, instead of being treated as edits.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.63...v8.64
