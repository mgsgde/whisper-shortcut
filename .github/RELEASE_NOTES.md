**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

A maintenance release: no new features, many fixes.

## Security
- **Mail search can no longer be abused to run other mail commands.** A crafted search text (for example from a prompt-injected email) could slip extra IMAP commands into the mail connection. Line breaks in search terms are now rejected. Mail headers with non-ASCII characters also decode correctly.

## Chat
- Meeting edits from Chat land in the chat that asked for them.
- Without an API key, no message is lost: Retry, Edit and the composer keep your text.
- A queued message no longer holds up the ones behind it, and deleted chats neither send queued messages nor come back with ⌘⇧T. Tool approvals are refused in archived chats.
- Saving in the Memory and Folder Map editors keeps facts Chat added while you were editing.

## Settings
- Settings saves only what you changed. It no longer undoes a model you picked with `/model`, a picker or `/pin`, no longer overwrites a Gemini key entered in the welcome tour, and no longer re-downloads an offline model you deleted.
- Reopening the welcome tour keeps its state, and its last step saves only your shortcuts.

## Offline models
- Downloading again after Cancel works, without a stale percentage.
- An offline model is loaded only once at a time, so two copies never sit in memory.

## Menu bar and recording
- Voice Feedback while the app is busy shows "Busy" instead of a missing-key message, and the menu reads "Stop Voice Feedback" while it records.
- The Read Aloud shortcut is ignored during another recording.
- The recording pill no longer stays hidden after a quick hide and show.

## Meetings and Writing Style
- A meeting chunk that cannot be transcribed no longer blocks retrying the later ones; its audio stays.
- Cancelling the Writing Style review no longer brings it back at every launch, and glossary lines you delete in the review stay deleted.

## Stability
- A full disk no longer crashes the app while logging.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.54...v8.55
