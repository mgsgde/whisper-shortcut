# Release Notes - Version 5.2.2

## Installation

Download the latest version from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases) or update through the App Store.

## Changes

### Improved Error Messages
- **Better feedback for missing offline models**: When an offline Whisper model is not yet downloaded, the app now displays a clear, user-friendly error message with step-by-step instructions on how to download the model, instead of showing technical error messages like "Error in reading the MIL network."

### Code Quality Improvements
- **Centralized UserDefaults keys**: All UserDefaults keys are now managed through a centralized `UserDefaultsKeys` enum, improving code maintainability and reducing the risk of typos.
- **Simplified model loading logic**: Refactored model loading to use centralized methods, making the codebase cleaner and easier to maintain.
- **Removed debug code**: Cleaned up commented-out debug code to improve production readiness.

### Documentation
- **Updated screenshots and documentation**: Added documentation and screenshots for the open-source feature.

## Technical Details

- Enhanced error handling in `LocalSpeechService` to detect and properly handle missing or incomplete WhisperKit model files
- Improved `SpeechErrorFormatter` to provide detailed guidance when models are not available
- Refactored `TranscriptionModel` with new `loadSelected()` and `isOfflineModelAvailable()` methods
- Replaced all hardcoded UserDefaults string literals with constants from `UserDefaultsKeys`
- Fixed bug in `FullApp.swift` where wrong KeychainManager method was called

---

For more information, visit the [GitHub repository](https://github.com/mgsgde/whisper-shortcut).
