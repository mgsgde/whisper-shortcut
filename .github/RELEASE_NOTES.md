**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## New
- **Better models once you add a key.** When you save an API key, WhisperShortcut lists the features still running on on-device models and offers to switch them to that provider's cloud models. Nothing changes without your OK, and it never asks in Offline Mode.
- **Writing Style learns on its own.** Turn it on once: your sent Gmail is imported right away and weekly, and dictations into Mail, Messages, WhatsApp, Slack and similar apps are kept on your Mac as examples. After 20 new examples you get an updated profile to review. Off by default.
- **OpenRouter is its own chat provider.** Pick any OpenRouter model from the new OpenRouter group in the chat picker, using the account from Settings → General. A custom endpoint that pointed at OpenRouter moves over automatically and keeps your model.

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
- **Closing tabs never deletes chats.** "Close Other Tabs" and "Close Tabs to the Right" now archive them, and "Delete permanently" and Clear Chat (⌘⇧K) ask first.
- **Meetings start in their own session.** Starting a meeting no longer turns an open chat into the meeting, and if the app is busy you get a notice instead of nothing.
- **Your own chat commands.** A Markdown file in the commands folder (Settings → Chat → Commands) becomes a slash command: `report.md` is `/report`. Meeting commands also get a one-click button above the meeting chat.
- **Fewer Keychain prompts.** API keys move to the modern macOS keychain, so the "WhisperShortcut wants to use your confidential information" prompt stops coming back after updates. You may see it one last time per key.
- **Your custom system prompt backup is kept while you edit.** Over-typing a prompt no longer replaces its backup with half-typed text.
- **Older models are gone from the pickers.** Gemini 3.5 Flash and 3.6 Flash and a set of superseded chat models are removed; if you had one selected, you move to its successor (Gemini 3.7 Flash for the Flash models).
- **Settings use the current tab names** everywhere, including in error messages, and model pickers are named consistently.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.46...v8.49
