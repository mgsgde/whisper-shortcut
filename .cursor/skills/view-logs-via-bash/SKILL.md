---
name: view-logs-via-bash
description: View application logs via the project's bash script. Use when debugging issues, investigating errors, or when the user asks to check or show logs. Logs are the primary way to see what the app is doing.
---

# View Logs via Bash

Logs are the primary debugging surface. View them via the project script (per the always-applied rule in `.cursor/rules/index.mdc`) — not via direct file access.

```bash
bash scripts/logs.sh [options]
```

| Purpose | Command |
|---------|---------|
| Last time window (e.g. 2 min) | `bash scripts/logs.sh -t 2m` |
| Live stream of all logs | `bash scripts/logs.sh` |
| Filter by text | `bash scripts/logs.sh -f 'PROMPT-MODE'` or `-f 'Error'` |
| Last hour | `bash scripts/logs.sh -t 1h` |

When debugging, check logs first (`-t 5m` / `-t 2m`) and use `-f` to filter by mode or errors (`PROMPT-MODE`, `Speech-to-Text`, `Error`).

## Notes

- `logs.sh` reads the **macOS unified-logging buffer** (`log show`/`log stream`). That buffer rolls over after a while, so for older sessions widen the window (`-t 24h` / `-t 48h`) and don't assume "no output" means it never happened.
- The buffer holds every `DebugLogger` call, but the app also keeps a structured **user-interaction log** (`interactions-YYYY-MM-DD.jsonl` under the canonical data dir, see `index.mdc` → Data Directories). That JSONL records the user message + final model response per interaction, but **not** individual chat tool calls — for the tool-call trail (e.g. AI Chat → Google Calendar), grep the unified log for `CHAT-TOOL-CALL` / `CHAT-TOOL-RESULT` / `GOOGLE-CALENDAR`.
