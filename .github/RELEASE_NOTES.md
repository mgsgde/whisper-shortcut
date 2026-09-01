# WhisperShortcut 8.04

**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

A correction release. 8.03 introduced the in-process offline model and called it the recommended way to run a local LLM. Then we measured it, and that claim did not hold — so this release says what the feature actually is.

## What the offline model is, and is not

- **It is the option with nothing to install.** Pick Qwen3 4B Instruct or Qwen3 8B, it downloads itself, and it runs on your Mac. No server, no port, no `ollama serve`.
- **It is not the fastest way to run a local model.** On the same model, a warm Dictate Prompt rewrite took about 1.3 s through a local Ollama server against about 4 s in-process, and the in-process path varied more from run to run. If you already run Ollama or LM Studio, the Local Server option remains the better pick — and the app now says so where you choose.
- The difference is prompt processing. A server keeps the cache of your system prompt in memory between requests; the in-process path rebuilds it every time. The framework's prefix cache was tried for this and removed again: restoring its 75 MB cache file costs about what re-processing the prompt costs.

Settings, the model list, and the model descriptions were reworded accordingly. Nothing about how the feature works has changed.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.03...v8.04
