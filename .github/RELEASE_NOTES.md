# WhisperShortcut 7.75

Stability release focused on long chat replies and Live Meeting summaries.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### Fixes
- **Fixed a freeze during long streaming chat replies.** As a reply grew, the chat window could stop responding and force a quit. Streaming updates are now paced to the length of the reply, so long answers stay smooth.
- **Fixed Live Meeting summary slowdowns.** On long meetings the live summary could fall behind and pile up repeated updates. Summary refreshes no longer overlap, and the running summary stays concise instead of growing without bound.

### Internal
- **Improved hang detection:** freeze diagnostics no longer misreport an open dialog as a hang, making real issues easier to spot.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.74...v7.75
