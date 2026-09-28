**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Dictate Prompt
- **Quick actions.** While a Dictate Prompt recording runs, your most frequent instructions (from the last 30 days) appear above the recording pill. Press Return or a number key 1–5 to run one without speaking; the arrow keys move the highlight, Esc hides the list and keeps recording. Speaking and pressing the shortcut again works exactly as before.
- **Writing Style (off by default).** Dictate Prompt can draft replies and messages the way you write them instead of in assistant prose. The app keeps a short profile per context (Email, Messenger, Work Chat, Default) plus a few messages you actually wrote, taken from your Gmail sent mail (with the Google connection) or pasted in Settings. You review the profile before it is saved. Turn it on in Settings → Smart Improvement → Writing Style. When it is on, the profile and a few of your messages are sent with each Dictate Prompt request to your Dictate Prompt model; local (offline) models do not get them.

## Recording
- **A silent microphone is now reported as an error.** A recording that contains no signal at all (for example because macOS revoked microphone access or the input device is dead) now shows an error pointing to System Settings → Privacy & Security → Microphone, instead of looking like you said nothing.

## Smart Improvement
- A run that fails only because of a temporary network error no longer waits a full 7 days before trying again.

## Under the hood
- Better diagnostics for timed-out requests and abandoned chats in the local usage log.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.25...v8.26
