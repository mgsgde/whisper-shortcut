**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Dictation is safer
- **Your recording is never lost when an on-device model fails.** If the offline model can't be loaded or prepared, the audio is kept and you get a Retry button instead of an empty result.
- **⌘1 no longer cancels a long Dictate Prompt.** Pressing the dictation shortcut while a long Dictate Prompt is still processing used to cancel it and throw the recording away. Now it shows "Busy" and the prompt finishes.
- **Dictate Prompt never takes an old clipboard as your selection.** With "Restore clipboard" on, pressing ⌘2 right after a paste could pick up the clipboard from before, not what you selected.
- **No "check your internet connection" in Offline Mode** when a spoken instruction turns out empty.

## Offline Mode
- **Whisper models are never deleted or re-downloaded while offline.** A model that fails to load is reported instead of removed.
- **Meeting summaries and Voice Feedback use the on-device Dictate Prompt model**, and never start a model download on their own.
- **Meetings in AI apps is switched off while Offline Mode is on**, so no transcript can reach a cloud provider through it.

## Other improvements
- **Your own chat commands.** A Markdown file in the commands folder (Settings → Chat → Commands) becomes a slash command: `report.md` is `/report`. Meeting commands also get a one-click button above the meeting chat.
- **Fewer Keychain prompts.** API keys move to the modern macOS keychain, so the "WhisperShortcut wants to use your confidential information" prompt stops coming back after updates. You may see it one last time per key.
- **Your custom system prompt backup is kept while you edit.** Over-typing a prompt no longer replaces its backup with half-typed text.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.46...v8.47
