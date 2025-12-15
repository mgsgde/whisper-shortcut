# Release Notes - Version 5.2.1

## Installation

Download the latest version from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases) or update through the App Store.

## Changes

### Improved Reliability
- **Enhanced retry logic for Gemini transcription requests**: The app now automatically retries failed transcription requests, improving reliability when dealing with network issues or temporary API service interruptions.

### Better Support for Large Audio Files
- **Improved Files API support**: Enhanced handling of large audio files (>20MB) with better error reporting and more robust upload process. The app now uses Google's resumable upload protocol more reliably.

### Developer Experience
- **Enhanced debugging capabilities**: Added debug options and improved logging for troubleshooting transcription issues during development.

### Internal Improvements
- **Release process improvements**: Enhanced GitHub Actions workflow for automated release creation with better release notes handling.

## Technical Details

- Fixed case-sensitive header parsing issue in Files API upload process
- Added retry logic for both inline and Files API transcription methods
- Improved error handling and logging throughout the transcription pipeline

---

For more information, visit the [GitHub repository](https://github.com/mgsgde/whisper-shortcut).

