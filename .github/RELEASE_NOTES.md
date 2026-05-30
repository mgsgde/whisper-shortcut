# WhisperShortcut 7.38

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Fixed a chat freeze on grounded replies

When a chat answer finished with web sources and citations, the app could spike the CPU and become unresponsive, requiring a force-quit.

The cause: the animated "typing" indicator was being re-laid-out 60 times a second together with the *entire* message list. The moment a large grounded reply was finalized (lots of sources, long text), that combination could wedge the main thread.

The typing indicator now animates independently of the message list, so finalizing even very large answers stays instant. Verified against replies far heavier than the ones that used to hang (14 sources, 33 citations, 4,700+ characters) — all commit in milliseconds.

### Reliability

- Added diagnostics around chat sends so any future hang in this area is immediately identifiable in the logs.
- Accessibility setup is smoother: the app now pre-registers itself in System Settings via the native prompt, making it more reliable to grant Accessibility permission.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v7.37...v7.38
