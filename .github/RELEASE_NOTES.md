## Offline dictation
- Plain Dictate with an offline model now finishes text the way Dictate Live already did: fillers are removed, a glued "…punkt" is split, "GdB" is written consistently, and quantities spoken as words become digits. Number words in ordinary prose stay as words.

## Connected AI apps (MCP)
- ChatGPT, Claude and other connected apps can now list and read WhisperShortcut's own documentation, including the practice playbook, so they answer "how does X work" from the docs instead of guessing.

## Settings
- In Dictation-only mode the Accounts tab stays visible while a cloud transcription model is selected, so you can still enter its key.
- Settings, the in-app Chat and MCP now agree on whether an old custom prompt replaces the built-in one.

## Fixes
- Services → Dictate Prompt respects Dictation-only mode.
- Model import opens your real home folder (for ~/.cache/huggingface and ~/.lmstudio/models) and skips hidden folders such as unfinished downloads.
- Converting an old custom prompt into additions no longer copies an old built-in prompt along with it.
- Practice playbook updated (v1.1).

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.99...v9.00
