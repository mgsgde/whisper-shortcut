---
name: debugging-workflow
description: Debugging in WhisperShortcut: add DebugLogger instrumentation (with right categories), rebuild, give developer a manual repro plan, then fetch and analyze logs. Use when the user reports a bug, asks to debug, wants logging added to understand flow, or the app hangs / freezes / pins the CPU.
---

# Debugging Workflow

## Rule

Logging rule (DebugLogger only) is in `.cursor/rules/index.mdc`; this skill covers the instrument → rebuild → repro → analyze-logs flow. For "just add logging" do only the instrumentation (and optionally rebuild).

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
| `logDebug()` or `log()` | Detailed flow / internals     |
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

## 3. Hangs / unresponsive UI / 100% CPU (different from a logic bug)

When the app freezes (beachball, pinned CPU), the logs go **silent at the freeze
point** — the last line is *where* it wedged, and `view-logs-via-bash` alone can't
go further. Switch tools:

**The app already captured it for you.** `MainThreadWatchdog` writes a symbolicated
`hang-<YYYYMMDD-HHMMSS>.txt` (with an `activity:` breadcrumb) to the app's Logs directory
whenever the main thread stalls ≥4s. Use the **analyze-chat-freeze** skill, which reads those
captures and carries a classification table of known hang families.

1. **Read the newest `hang-*.txt` first** — do not hand-roll a capture when one exists.
2. Only if no capture exists: `pgrep -x WhisperShortcut`, then
   `sample <pid> 3 -mayDie > /tmp/ws_hang.txt`.
3. **Correlate** the last log timestamp with the trigger, then add `DebugLogger` tripwires
   around that step so the next occurrence is unambiguous.
4. The app won't self-recover — `kill -9 <pid>` before rebuilding.

---

## When to apply

- Bug report / "it doesn't work" / "debug" / "figure out why" → full flow (instrument → rebuild → repro → logs).
- App froze / beachball / spinning / unresponsive / pinned CPU → section 3 (`sample` the process first).
- "Add logging" / "see what's happening" → instrumentation only (optionally rebuild).
- "View existing logs" only → use **view-logs-via-bash** instead; skip for pure feature work with no bug or visibility request.
