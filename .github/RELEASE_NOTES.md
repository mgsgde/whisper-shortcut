# WhisperShortcut 7.31

Stability release focused on Read Aloud — the feature that shipped in 7.30 had a handful of edge cases that left the menu bar busy or surfaced a misleading "no text selected" error.

## Read Aloud fixes
- **"No text selected" on apps that respond slowly to Cmd+C.** The shortcut used to wait a fixed 150 ms after the synthetic Cmd+C and then read the clipboard — too short for some apps, so it would fall back to a stale clipboard or an empty read. It now polls `NSPasteboard.changeCount` for up to 500 ms and only proceeds once the source app has actually written the selection.
- **Long text and non-1× playback no longer get stuck.** Chunked TTS (long text) and non-1× speed playback could leave the menu bar in `.processing` until the next user action. Cancellation races on the chunk pipeline and a silent Objective-C exception in the audio-format setup were the culprits.
- **Stop reliably tears down everything.** The stop path now cancels the rewrite stage, the network call, the audio engine, and the menu bar state through one unified teardown helper.
- **Double-press during the wait window no longer orphans a task.** Pressing the shortcut twice in quick succession while the first press is still copying the selection is now recognized as "stop" instead of starting a second pipeline on top of the first.

## Shortcut recorder
- Shift-only combinations on printable keys are now rejected — macOS routes them to text input instead of the hotkey handler, so they would have silently failed to fire.

## Behind the scenes
- Internal refactor of the shortcut-config plumbing — no user-visible change.
- `scripts/rebuild-and-restart.sh` now matches the app by exact executable name and verifies termination before relaunching, so a stale instance can't survive a rebuild.

## Installation
Download the latest `.dmg` from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Full changelog

[Compare v7.30…v7.31](https://github.com/mgsgde/whisper-shortcut/compare/v7.30...v7.31)
