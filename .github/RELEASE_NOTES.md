## Full-Screen Apps
- Dictate Prompt's floating pill and result popups now reliably appear over full-screen apps and windows in native full screen (e.g. Citrix Workspace or a browser in full-screen mode).
- The pill's drag cursor now resets correctly when the pill hides.

## Meetings and Dictation
- A dictation that fails during a live meeting now keeps your recorded audio and offers a Retry button instead of losing it.
- WhisperShortcut no longer loads the Silero voice-detection model at launch, so startup is faster.
- Dictate Prompt no longer leaks its own planning text into replies.
- In dictation-only mode, readiness checks and the restore-purchase message now correctly follow your selected model and Offline Mode state.

## Templates and Writing Style
- Writing-style revisions now change only the lines that actually changed, instead of rewriting the whole text.
- Template and writing-style edits always wait for your review before being applied.
- Updating a template no longer brings back a template you had deleted.
- Template proposals now correctly detect duplicates by comparing both name and instructions.

## Privacy
- The screen-context consent prompt now always appears before an MCP connection can turn screen access on, and shows the correct text.

## Model Import
- Importing models no longer gets stuck on directory symlink cycles.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v9.08...v9.09
