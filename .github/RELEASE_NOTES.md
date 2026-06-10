# WhisperShortcut 7.59

## Installation

Download the latest `WhisperShortcut.app` from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), move it to your Applications folder, and launch it.

## What's New

### Fixes

- **No more empty-list flash when sending a new chat message.** In long sessions the message list could briefly clear out the moment you pressed Send, leaving only the typing indicator visible until the response started streaming. Cause: the scroll-anchor reset that protects against a SwiftUI layout wedge was being applied on every list mutation — including plain appends, where it isn't needed. The reset now only runs on the paths where an anchored message could actually disappear (removals, retries, finalization), and the visible list stays put on Send.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.58...v7.59
