---
name: debugging-workflow
description: Debugging in WhisperShortcut: add DebugLogger instrumentation (with right categories), rebuild, give developer a manual repro plan, then fetch and analyze logs. Use when the user reports a bug, asks to debug, or wants logging added to understand flow.
---

# Debugging Workflow

## Rule

When debugging or adding visibility: use **DebugLogger** only (never `print`/`NSLog`/custom log files). For a full debug run: **instrument → rebuild → give developer a repro plan → then inspect logs**. For "just add logging" do only the instrumentation (and optionally rebuild).

---

## 1. Instrumentation (how to add logs)

- Log function entry/exit, parameters, return values, state changes. Use structured messages.
- **Categories** (choose the right one):

| Method         | Use for                        |
|----------------|--------------------------------|
| `logNetwork()` | API calls, requests, responses |
| `logAudio()`   | Recording, playback, chunking  |
| `logSpeech()`  | Transcription, prompt, TTS    |
| `logError()`   | Errors and failures           |
| `logDebug()`   | Detailed flow / internals     |
| `logInfo()`    | General info                  |
| `logWarning()` | Warnings                      |
| `logUI()`      | UI / menu / window events     |
| `logSuccess()` | Successful completion         |

**Example:**

```swift
DebugLogger.logSpeech("transcribe(start) url=\(audioURL.lastPathComponent)")
// ...
DebugLogger.logSpeech("transcribe(done) chars=\(result.count)")
DebugLogger.logError("API request failed: \(error.localizedDescription)")
```

---

## 2. Full debug flow (when finding a bug)

1. **Add instrumentation** (see above) so the relevant path is visible in logs.
2. **Rebuild**: `bash scripts/rebuild-and-restart.sh`
3. **Give the developer a short plan**: numbered steps to reproduce (e.g. "1. Start app, 2. Trigger Speech-to-Prompt with shortcut X, 3. Say Y, 4. Wait for processing"). Ask them to do it and say when done.
4. **After they reproduced**: use **view-logs-via-bash** (`bash scripts/logs.sh -t 5m` or `-f 'PROMPT-MODE'`), analyze logs, summarize findings and suggest fix or next step.

---

## When to apply

- User reports a bug or "it doesn’t work" → full flow (instrument → plan → logs).
- User asks to "add logging" or "see what’s happening" → instrumentation (and optionally rebuild).
- User asks to "debug" or "figure out why" → full flow.

## When to skip

- User only wants to **view** existing logs → use **view-logs-via-bash** only.
- Purely implementing a feature with no bug or visibility request.
