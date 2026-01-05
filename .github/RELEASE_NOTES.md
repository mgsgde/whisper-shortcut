# Release Notes - Version 5.3.0

## Installation

Download the latest version from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases) or update through the App Store.

## Changes

### 🎉 Major Features

- **Chunked Audio Transcription**: Added support for chunked audio transcription for long recordings. The app now automatically splits long audio recordings into smaller chunks and processes them in parallel, significantly improving performance and reliability for extended transcription sessions.

### ✨ Enhancements

- **Per-Chunk Status Grid UI**: New real-time status grid interface that provides visibility into the parallel processing of audio chunks. You can now see the progress and status of each chunk as it's being processed, giving you better insight into the transcription workflow.

### 🐛 Bug Fixes

- **Long Recording Crash Fix**: Fixed a critical crash that occurred when processing very long recordings. The app now handles extended recording sessions reliably.

### 🔧 Improvements

- **CrashLogger Refactoring**: Improved crash logging by using FileManager for log directory path management, making the logging system more robust and reliable.

### 🧹 Maintenance

- Updated `.gitignore` to exclude `.claude/` and `.env` files from version control.

---

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v5.2.6...v5.3.0
