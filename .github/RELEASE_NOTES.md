**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Offline Chat
- **A stronger offline model for Chat.** On Apple Silicon Macs with 16 GB of RAM or more, Chat can now use **Qwen3.5 9B (Offline)** (~5.6 GB, `/mlx9b`). It is slower than the default Qwen3 4B but knows more. It is for Chat only and never used by Dictate Prompt or as the Offline Mode fallback. The 4B stays the default.
- **More honest offline answers.** The offline model now gets a short prompt of its own that tells it it has no internet and no tools, so it stops claiming it searched the web or read your email.
- The text box now says "no web search or tools" when an offline model is selected, instead of a notice inside the first reply.

## Under the hood
- Tests no longer depend on which chat model is selected on the developer's Mac, and a flaky live test was fixed.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.41...v8.42
