# WhisperShortcut 7.14

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Fixed

- **Recent chat edits are no longer lost on rebuild or external kill**: `pkill` (used by `scripts/rebuild-and-restart.sh` and most third-party tooling) sends `SIGTERM` by default, which previously terminated the app before `applicationWillTerminate` could run — meaning any chat session change still inside the 2-second debounce window was lost. The app now catches `SIGTERM` / `SIGINT` / `SIGHUP` and routes through a clean shutdown so the chat session store always flushes to disk first.
- **Grok tool calls now stream reliably**: Three latent bugs in Grok's Chat Completions parsing — string-keyed tool-call ordering (which put `10` before `2`), argument accumulators getting wiped if `name` arrived mid-stream, and tool-call IDs not round-tripping back to the response turn — are all fixed. Parallel tool calls and tool-result matching now behave like the OpenAI path.
- **Grok rate limits and bad API keys surface clearly**: The Grok Responses API and Chat Completions endpoints now map HTTP 401 to "API key is invalid" and HTTP 429 to a rate-limit (same as Gemini and OpenAI), instead of presenting both as opaque network errors. Rate-limit signals are now also picked up by the cross-request backoff coordinator.
- **OpenAI Dictate Prompt text follow-ups give a clear error**: If you select an OpenAI model as your Dictate Prompt model and use the text-driven Prompt & Read flow, you now get an actionable "switch the Dictate Prompt model to Gemini in Settings" message instead of the misleading "not a Gemini model" error.

### Changed

- **Termination logging for diagnosing spontaneous restarts**: The app now logs every shutdown decision — launch PID/version, the signal that arrived (if any), the `applicationShouldTerminate` outcome, duplicate-instance exits — under the `APP-LIFECYCLE` category. Useful when troubleshooting unexpected restarts via `bash scripts/logs.sh -t 10m -f APP-LIFECYCLE`.
- **Privacy and Terms updated**: Privacy and Terms documents have been refreshed to reflect the current provider lineup (Google Gemini, OpenAI, xAI) and data-handling behavior.

### Internal

- Internal refactors only: deduplicated the Responses-API request translator across the OpenAI and Grok providers, consolidated three near-identical `URLSession` factories into one shared session, and pulled the 10-second history-transcription timeout pattern into a single helper used by both the Gemini and OpenAI Dictate Prompt paths. No user-visible behavior change from these.

## Full changelog

[Compare v7.13…v7.14](https://github.com/mgsgde/whisper-shortcut/compare/v7.13...v7.14)
