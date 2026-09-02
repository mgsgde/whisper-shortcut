# WhisperShortcut 8.06

**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

Stop during a stuck transcription now really stops. Retry after a failed dictation pastes the result. Offline Mode can read text aloud with on-device macOS voices.

## Dictate

- **Stop cancels the request.** Pressing Stop while a transcription is in flight cancels the provider call instead of leaving it running in the background.
- **Retry works again.** After a failed dictation, Retry re-runs the same audio and pastes the transcript instead of silently dropping it.
- **A failed dictation no longer overwrites your clipboard** with the error text. The popup still shows what went wrong.
- **Correct, Format, and Rephrase** are in the menu under Dictate Prompt, so you do not have to speak those verbs through speech-to-text.

## Offline Mode

- **Read Aloud works offline** using on-device macOS voices. Turning Offline Mode on selects that voice automatically.
- **Onboarding picks the model it just downloaded**, so the first dictation does not fail with "model not downloaded".
- Offline-only setups no longer force Settings open on every launch.

## Chat

- **Claude (Anthropic)** is documented as a chat provider — Settings, `/claude`, and the in-app Chat all agree.
- Creating or deleting a calendar event, changing a Trello card, or opening a URL now asks first.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.05...v8.06
