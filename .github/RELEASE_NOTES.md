# WhisperShortcut 7.74

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Local LLM for Dictate Prompt
- **Run Dictate Prompt fully offline** with a local OpenAI-compatible server such as **Ollama** or **LM Studio** — configure the endpoint URL and model ID in Settings.

### Chat improvements
- **Better email answers:** Gmail searches no longer fan out into many calls and dead-end without a reply — the chat now searches once, reads only the most relevant messages, and summarizes what it found.
- **Consistent tone:** replies match your form of address and stay consistent throughout an answer.
- **Sidebar:** the Today and Yesterday groups are expanded by default.

### Fixes
- **Gemini 3 chat:** fixed an HTTP 400 that could break tool calls when a function call's thought signature was dropped.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.73...v7.74
