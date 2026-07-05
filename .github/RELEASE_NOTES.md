# WhisperShortcut 7.77

Onboarding, chat readability, and permissions-accuracy release.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Improvements
- **Custom OpenAI-compatible chat endpoint.** Point the chat window at any OpenAI-compatible server (e.g. self-hosted inference), including a ready-made OpenInference preset.
- **Better onboarding.** The offline Whisper option is now always visible on the API-key step (no more hidden below the scroll), the final "You're ready" overview includes the Screenshot shortcut and tells you where the app lives — in your menu bar — and the window no longer clips its footer buttons.
- **Chat replies are easier to read.** Prose the model wraps in ```markdown/```text fences (e.g. email drafts) now wraps like normal text instead of being cut off at the right edge; real code keeps its structure with a visible scroll indicator.
- **The chat composer shows the active model.** The placeholder now reads "Message Gemini 3.5 Flash…" (or Grok/GPT accordingly) instead of always "Message Gemini…".
- **More honest permission status.** Accessibility shows "Not requested" instead of a red "Denied" until the app has actually asked, and the "You're ready" overview reflects the real Screen Recording status.

### Fixes
- **Fixed a chat freeze caused by text selection.** Selecting-enabled message text could enter a self-sustaining font-invalidation loop during streaming and pin the CPU; message copying now goes through the copy buttons.
- **Transcription clipboard handling fix.** Dictation results land on the clipboard more reliably.
- **App Store build accuracy.** The App Store variant no longer advertises auto-paste in onboarding (the feature is omitted there) and the final overview names the correct permissions for Dictate Prompt.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.76...v7.77
