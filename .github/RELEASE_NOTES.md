**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Claude & other AI apps
- **No more timeouts while a dialog is open.** Requests from Claude and other AI apps used to hang and time out while WhisperShortcut showed a dialog. They now return right away with a clear "WhisperShortcut is busy" message.
- **More robust connection.** A short Keychain hiccup after login no longer resets the access token, so configured clients keep working. Stalled requests can no longer slow the app down.
- **Live transcripts stay complete.** If a late chunk lands earlier in a running meeting's transcript, the next live update sends the corrected transcript instead of skipping it.
- Glossary terms from an AI app now wait for your approval when the access level is set to "propose", as the setting promises.
- Every tool tells AI apps whether it only reads or changes something, and the tool list no longer changes mid-session.

## Setup and settings
- The dictation setup step only lets you continue once the selected transcription model can actually run.
- A missing API key in the Try-it step opens Settings → Accounts, where you add it.
- Switching Offline Mode always clears the Dictate Prompt conversation history.

## Smart Improvement
- Learning your vocabulary costs less: Smart Improvement asks the model for less reasoning.
- Glossary terms are recognised the same way everywhere (up to 5 words), and changes made by AI apps show as "AI app (MCP)" in the history.

## Fixes
- ChatGPT plan sign-in uses checked randomness and accepts only genuine openai.com hosts.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.60...v8.61
