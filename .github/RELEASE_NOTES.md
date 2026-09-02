# WhisperShortcut 8.08

**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

Offline dictation no longer pays a cold start before every transcript. On an M1 Pro with Whisper Large v3 Turbo, a 25-second dictation after a break went from about 13 seconds to about 4.

## Offline dictation is faster after a pause

- **The model loads while you speak.** Pressing the dictation shortcut now starts loading the offline model straight away, so the weights are ready by the time you stop talking instead of being loaded afterwards, with you waiting.
- **The model you dictate with stays loaded.** It used to be released after five idle minutes, which meant anyone dictating a few times an hour paid the full load — and a further one-time cost on the first transcription after it — nearly every time. It is still released when macOS is short on memory, and as soon as you switch to a cloud model.
- No downloads start behind your back: a model that is not on disk yet is still offered at dictation time, with progress, exactly as before.

## Chat

- **Repeated lookups stop costing a round trip.** When a model searched your shared folder for something that was not there, it would often re-issue the same search several times, each one a full request to the provider. A repeat is now answered from the first result, and a search whose words already came up empty is flagged even when the folder differs.
- **Grok 4.6 is the default Grok model**, and the two Grok entries describe what they actually are — 4.6 the flagship, 4.3 the cheaper option with a 1M-token context.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.07...v8.08
