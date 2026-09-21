**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Offline models
- **An interrupted Whisper download no longer looks complete.** A model folder that Hub had created but not finished filling used to count as downloaded, so dictation would try to load it and hang. A model now counts as downloaded only when its compiled files are actually on disk; otherwise the download resumes the next time you dictate.
- **Local model loading and decoding have a deadline.** Loading an on-device Whisper model or decoding a recording with it used to run without any ceiling — the app could sit in "transcribing" for minutes. Both now stop after a fixed wall-clock budget and show the retryable timeout error instead. A load that was cut off or cancelled is no longer mistaken for a corrupt download.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.20...v8.21
