# WhisperShortcut 8.03

**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

This release adds an in-process local LLM for Chat and Dictate Prompt: pick an offline model, it downloads itself, and it runs on your Mac with no server to install. If you already run Ollama or LM Studio, keep using it — measured on the same model, the server answers noticeably faster.

## Offline Chat and Dictate Prompt on MLX

- **Qwen3 4B Instruct** downloads in the app and runs in-process via MLX, next to Whisper Turbo. About 2.3 GB. Chat and Dictate Prompt share one copy in RAM.
- **Qwen3 8B** is offered as a second offline tile (~4.5 GB). Better quality, but tight on 8 GB Macs that already hold Whisper Turbo.
- **Downloads look like Speech-to-Text.** Progress in the picker, an Available Models list with percent, Delete, and Cancel. Cancel aborts the Hugging Face transfer; it is not shown as a failed download.
- **Ollama and LM Studio stay available, and stay the faster choice.** On the same model, a warm rewrite took about 1.3s through a local Ollama server against about 4s in-process. The difference is prompt processing, which the server avoids by keeping its cache in memory between requests. MLX is the option for people who would rather not run a server at all.

## Chat no longer writes a looping novel

- If Gemini (or any streamed chat model) starts repeating the same sentence, the stream stops after the third copy, the answer so far is kept, and a queued follow-up still sends. Stop still cancels the in-flight turn.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.02...v8.03
