# WhisperShortcut 7.49

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### AI Chat: generate images in the conversation

- **Ask the assistant to create images** (Gemini image generation, including Nano Banana and Pro). Generated images appear inline in the chat.
- **`generate_image` tool** so the model can call image generation when it fits the task (e.g. diagrams or illustrations from your prompt).

### Chat reliability and performance

- **Smoother scrolling in long chats** — scroll position no longer triggers a full chat refresh every frame; reading position is saved with a short debounce.
- **Fewer freezes at 100% CPU** when scrolling or after sending messages — fixes `SelectionOverlay` loops on tables, clears scroll anchors before list updates, and caches prose layout height.
- **Retry** on your last user message to resend the same prompt and attachments after removing the failed or unwanted reply.
- **Copy user message** now includes pasted selection/content blocks, not only the typed text.
- **Quit no longer deadlocks** when saving chat sessions (`flushToDisk` on the main thread).

### Read Aloud

- **Menu bar shows a speaking indicator** while Read Aloud playback is active (same visual feedback as other busy states).

### Other

- Removed unused **Prompt & Read** code path.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.48...v7.49
