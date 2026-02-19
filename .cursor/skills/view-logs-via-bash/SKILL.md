---
name: view-logs-via-bash
description: View application logs via the project's bash script. Use when debugging issues, investigating errors, or when the user asks to check or show logs. Logs are the primary way to see what the app is doing.
---

# View Logs via Bash

## Rule

View logs via the project's bash script – **not** via direct file access or other means.

## What to run

From project root:

```bash
bash scripts/logs.sh [options]
```

**Common variants:**

| Purpose | Command |
|---------|---------|
| Last time window (e.g. 2 min) | `bash scripts/logs.sh -t 2m` |
| Live stream of all logs | `bash scripts/logs.sh` |
| Filter by text | `bash scripts/logs.sh -f 'PROMPT-MODE'` or `-f 'Error'` |
| Last hour | `bash scripts/logs.sh -t 1h` |

- **When debugging, check logs first** (e.g. `-t 5m` or `-t 2m`) before making other assumptions.
- Use `-f` to filter by mode or errors (e.g. `PROMPT-MODE`, `Speech-to-Text`, `Error`).

## When to apply

- User reports a bug or unexpected behavior → check logs with a time window.
- User explicitly asks for logs or "what's happening".
- After a rebuild/repro: view logs to understand error messages or flow.

## When to skip

- When the user only wants to change code and nothing related to debugging/logs.
