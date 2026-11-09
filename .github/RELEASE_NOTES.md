## Offline models
- **Import models you already have.** In Settings, you can now import model files that are already on your Mac (for example from a Hugging Face cache) instead of downloading them again. Each section only offers models that fit it, half-downloaded models are never offered, and the import shows progress and can be cancelled.
- **Onboarding downloads right away.** Picking Offline in onboarding now starts the offline model download immediately. The status line shows the progress, and the greyed-out Continue button explains why it is waiting.

## Chat and tuning
- The approval card for a change to your app instructions now shows exactly what is added and removed, like the review window for AI apps.
- A new chat no longer opens as a blank pane.
- Chat and AI apps connected over MCP can now also add to the default Dictate Prompt and Chat instructions on a fresh install; the section limit grows with the default text.
- For tuning on request, the usage log now also records errors, Read Aloud requests and which chat tools ran, and keeps a history of configuration changes, so a model does not re-add something you removed. Arguments, results and full prompt texts are never logged.

## Fixes
- Stopping or cancelling a live meeting no longer shows a "Transcription Failed" message.
- Opening Accessibility or Screen Recording in System Settings first refreshes the list, so WhisperShortcut appears there without adding it by hand.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.88...v8.89
