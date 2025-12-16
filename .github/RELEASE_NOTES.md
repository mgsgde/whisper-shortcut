# Release Notes - Version 5.2.3

## Installation

Download the latest version from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases) or update through the App Store.

## Changes

### Bug Fixes

- **Fixed transcription interruptions and race conditions**: Resolved an issue where transcriptions could be interrupted or processed multiple times when the shortcut was pressed during an active transcription. The app now properly tracks and prevents duplicate processing of audio files, ensuring each transcription completes successfully without interruptions.

### Improved Reliability

- **Better state management**: Enhanced audio processing state tracking to prevent race conditions and ensure clean transitions between recording, processing, and idle states.
- **Automatic cleanup**: Improved cleanup of audio files when transcriptions are cancelled or completed, preventing file system clutter and potential conflicts.

## Technical Details

- Added `processedAudioURLs` tracking to prevent duplicate processing of the same audio file
- Implemented `currentTranscriptionAudioURL` tracking for proper cancellation handling
- Enhanced `audioRecorderDidFinishRecording` with duplicate detection and state validation
- Improved cleanup logic in `performTranscription` and `performPrompting` methods
- Added immediate file cleanup when transcriptions are cancelled

---

For more information, visit the [GitHub repository](https://github.com/mgsgde/whisper-shortcut).
