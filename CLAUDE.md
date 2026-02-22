# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WhisperShortcut is a macOS menu bar application for real-time audio transcription with four modes:
- **Speech-to-Text**: Transcription using Google Gemini (cloud) or Whisper (offline)
- **Speech-to-Prompt**: Voice instructions that modify clipboard text via AI
- **Read Aloud**: Text-to-speech using AI voices
- **Prompt & Read**: Combined AI processing + TTS workflow

**Stack**: Swift 5.9+, Cocoa, AVFoundation, Xcode 16.0+, macOS 15.5+

## Build & Development Commands

```bash
# Build and restart app (MANDATORY after every code change)
bash scripts/rebuild-and-restart.sh

# Install to /Applications
bash install.sh

# Stream logs (essential for debugging)
bash scripts/logs.sh
bash scripts/logs.sh -t 5m              # Last 5 minutes
bash scripts/logs.sh -f 'PROMPT-MODE'   # Filter by pattern

# Create release (triggers GitHub Actions)
bash scripts/create-release.sh
```

## Architecture

### State Machine (Central Pattern)

All application state flows through `AppState.swift`:
```swift
enum AppState {
  case idle
  case recording(RecordingMode)
  case processing(ProcessingMode)
  case feedback(FeedbackMode)
}
```

(TTS playback is not a separate state; the app remains in `processing` or transitions to `feedback`/`idle`.)

**Critical**: Always transition through AppState - never manipulate UI or state directly.

### Core Services

| Service | Purpose |
|---------|---------|
| `MenuBarController.swift` | Central orchestrator, owns all services, manages shortcuts |
| `SpeechService.swift` | Main business logic for transcription and prompting |
| `GeminiAPIClient.swift` | All Google Gemini API interactions with retry logic |
| `ChunkTranscriptionService.swift` | Parallel processing of long audio (45-second chunks) |
| `ChunkTTSService.swift` | Text-to-speech chunking |
| `AudioRecorder.swift` | Audio capture (24kHz, mono, 16-bit WAV) |
| `ClipboardManager.swift` | System clipboard integration |
| `KeychainManager.swift` | Secure API key storage |

### Data Flow (Transcription Example)

```
User shortcut → AppState = .recording(.transcription)
→ AudioRecorder.startRecording()
→ User stops → AppState = .processing(.transcribing)
→ SpeechService.transcribe() → GeminiAPIClient
→ ClipboardManager.copyText()
→ AppState = .feedback(.success) → .idle
```

## Critical Rules

### 1. Always Rebuild After Changes
```bash
bash scripts/rebuild-and-restart.sh
```

### 2. Use DebugLogger Exclusively
```swift
// CORRECT
DebugLogger.log("Message")
DebugLogger.logError("Error occurred")
DebugLogger.logNetwork("API call")

// NEVER USE
print()    // ❌
NSLog()    // ❌
os_log()   // ❌
```

Available methods: `log()`, `logError()`, `logDebug()`, `logInfo()`, `logWarning()`, `logSuccess()`, `logUI()`, `logAudio()`, `logNetwork()`, `logSpeech()`

### 3. State Transitions
```swift
// CORRECT: Use AppState
appState = appState.startRecording(.transcription)

// WRONG: Direct manipulation
isRecording = true  // ❌
```

### 4. Async/Await & Cancellation
- Use async/await throughout (no callbacks)
- Always support cancellation with `Task.checkCancellation()`
- UI updates on main thread via `MainActor`

### 5. English Only
All text in the repository must be in English: UI strings, dialogs, labels, tooltips, code comments, default prompts, examples in prompts, and documentation. Do not introduce or retain German or other non-English text.

## Key Files

- `FullApp.swift` - App entry point
- `AppState.swift` - State machine
- `AppConstants.swift` - Default prompts, chunking parameters
- `TranscriptionModels.swift` - Model definitions (Gemini, Whisper)
- `SpeechErrorFormatter.swift` - User-friendly error messages

## Settings Structure

Settings tabs in `WhisperShortcut/Settings/Tabs/`:
- `GeneralSettingsTab.swift` - API key, general config
- `SpeechToTextSettingsTab.swift` - Transcription settings
- `SpeechToPromptSettingsTab.swift` - Prompt mode settings
- `ReadAloudSettingsTab.swift` - TTS settings
- `PromptAndReadSettingsTab.swift` - Combined mode settings

## Cursor Skills (Project)

| Skill | When to use | Action |
|-------|-------------|--------|
| **push-after-rebuild** | User says push, commit, deploy to git | 1. Run `bash scripts/rebuild-and-restart.sh` 2. Only if build succeeds → commit & push |
| **rebuild-after-change** | After any code change (Swift, features, bugs) | Run `bash scripts/rebuild-and-restart.sh` once at end of edits |
| **view-logs-via-bash** | Debugging, errors, user asks for logs | Use `bash scripts/logs.sh` (e.g. `-t 2m`, `-f 'PROMPT-MODE'`) — no direct log file access |

## Cursor Rules (`.cursor/rules/index.mdc`, always applied)

- **KISS**: Prefer simplest, most robust solution.
- **Rebuild**: After every code change run `bash scripts/rebuild-and-restart.sh`.
- **DebugLogger only**: Use `DebugLogger.log()`, `logError()`, etc.; never `print()`, `NSLog()`, `os_log()`.
- **No automated tests**: Tests run manually in Xcode.
- **Understand first**: Clarify requirements before implementing.
- **Logs for debugging**: Check logs with `bash scripts/logs.sh -t 2m`; use DebugLogger categories (`logNetwork`, `logAudio`, `logSpeech`, …).
- **English only**: All text (UI, comments, prompts, docs) must be in English; no German or other non-English.

## Testing

Tests are executed manually in Xcode - do not run automated tests from CLI.
