# WhisperShortcut 8.02

**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

This release is about dictating without the internet: a single switch that keeps everything on your Mac, a much better offline model, and downloads you no longer have to manage.

## Offline Mode

- **One switch makes the app device-local.** Settings → Privacy & Permissions (also offered during onboarding): dictation runs on an on-device Whisper model, every request to the internet is blocked at the network layer, and no transcript, prompt or audio sample is written to the usage log. Requests to your own machine or local network still work, so a Whisper server or Ollama on your network stays available.
- Built for regulated dictation — patient findings, case notes — where "the recording never leaves this device" has to hold whatever else is configured.

## Offline dictation got faster and more accurate

- **Whisper Large v3 Turbo** is the new recommended offline model: the accuracy of Large v3 at roughly half the download and several times the speed.
- **You no longer manage the download.** Selecting an offline model downloads and loads it in the background with visible progress. Dictate before it is ready and the recording is kept and transcribed as soon as the model is — the app never quietly falls back to a cloud model you did not pick.
- **Large models now load on the GPU** instead of the Neural Engine. The Neural Engine needs CoreML to compile the model first, which for Large v3 Turbo ran over 14 minutes here without finishing; the GPU loads the same model in about 6 seconds. Tiny and Base compile quickly and keep the Neural Engine.
- Medium and Large v3 are no longer offered — Turbo beats Medium at the same size and matches Large v3 at half of it. Already downloaded one? It stays selectable and deletable.

## Add Selection to Glossary

- Select a correctly spelled term anywhere and press ⌘7 (direct-download build). It is appended to the Glossary verbatim, with a duplicate check. No model is involved, which makes it the way to grow the Glossary while Offline Mode is on.

## Dictate Prompt with a local model

- **Fixed: the local model had nothing to edit in the App Store build.** It was being told to edit the highlighted region of a screenshot it could never receive, and answered with your instruction tidied up instead of your text. A local model now always reads the text to edit from the clipboard.
- **Faster first word.** Thinking is now switched off in the spelling Ollama actually reads, so a reasoning model no longer spends its first seconds thinking before any text appears. The model and its prompt cache are warmed while you are still speaking, and the transcription step is warmed alongside it.

## Other

- The Dictate settings tab now leads with the field the selected model actually reads.
- GPT Transcribe no longer claims to honour the dictation prompt — it is a pure speech-to-text model and ignores it; your Glossary still applies as keyword hints.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.01...v8.02
