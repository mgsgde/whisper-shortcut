# WhisperShortcut 7.9

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Fixed

- **Stuck "Recording" state after rapid restart**: Fixed a race condition where the app could get permanently stuck in the recording state if a new recording was started within ~100ms of the previous one ending (e.g. after a silent skip). The deferred AVAudioRecorder cleanup is now identity-checked so it never clobbers the recorder of a freshly started recording. Stop and Stop Dictate now reliably end the recording in this scenario.

## Full changelog

[Compare v7.8…v7.9](https://github.com/mgsgde/whisper-shortcut/compare/v7.8...v7.9)
