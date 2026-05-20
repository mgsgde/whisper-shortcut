# WhisperShortcut 7.23

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Internal

- Reduced the chat view's `sendMessage` to a pure slash-command dispatcher. The dead content-build path (attachment assembly, pasted-block XML wrapping, send dispatch) was removed since `submitComposer` already pre-filters slash commands and real chat content goes through `sendComposed`. Code-clarity cleanup with no user-visible change.

## Full changelog

[Compare v7.22…v7.23](https://github.com/mgsgde/whisper-shortcut/compare/v7.22...v7.23)
