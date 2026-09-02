# WhisperShortcut 8.05

**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

The built-in offline model now keeps its prompt in memory between requests, so a typical Dictate Prompt rewrite starts several times faster than in 8.04.

## Faster first word from the built-in model

- **The system prompt is no longer rebuilt every time.** On a quiet machine, prompt processing dropped from about 3 s to about 0.6 s. Generation was already in the same range as a local server.
- **It still downloads itself — no server to install.** If you already run Ollama or LM Studio, that remains the more stable pick when the Mac is also holding another model in memory.
- The cache is primed while you speak, the same way the local-server path already warmed its model.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.04...v8.05
