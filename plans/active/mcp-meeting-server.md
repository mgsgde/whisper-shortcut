# MCP server: meeting transcripts in Claude (and any MCP client)

Status: built on feat/mcp-meeting-server (2026-10-19); v1 shipped as planned plus `until` on get_meeting for long meetings

## Problem

The in-app Chat lacks context that Claude has (files, connectors, memory), so meetings get
discussed in Claude instead — but Claude cannot see the transcript, so it is copy-pasted in
pieces while the meeting runs. Goal: Claude reads the live and past transcripts itself.

## What already exists (verified)

- Transcript is appended to disk live, chunk by chunk:
  `LiveMeetingSession.appendToTranscript` → `Meetings/<stem>.txt`, format
  `[mm:ss] Speaker A: …` blocks separated by a blank line. Notes `<stem>.notes.md`, summary
  `<stem>.summary.md` (`MeetingListService.notesURL/summaryURL`).
- Which meeting is live: `LiveMeetingTranscriptStore.shared.isSessionActive` +
  `currentMeetingFilenameStem`.
- Parsing: `MeetingListService.parseTranscriptFile(at:)` → `[LiveMeetingChunk]` (startTime, text).
  Listing: `MeetingListService.refresh()` / `meetings`.
- Both entitlement files already have `com.apple.security.network.server`, so a loopback
  listener works in the App Store build too.
- `LoopbackOAuthListener.swift` already has the BSD-socket bind on 127.0.0.1 (NWListener
  failed with EINVAL there). The new server reuses that pattern, but stays running and serves
  many requests.

## Design

### Transport
MCP "Streamable HTTP", JSON-only responses (the spec allows `application/json` instead of SSE):
- `POST /mcp` with a JSON-RPC body → one JSON response. Notifications → `202 Accepted`.
- `GET /mcp` → `405` (no server-initiated stream needed in v1).
- Bound to `127.0.0.1` only, fixed default port **47823** (so client config stays valid across
  restarts), `Connection: close` per request, body cap 1 MB.
- Methods: `initialize` (echo the client's `protocolVersion` if supported, else `2025-06-18`;
  capabilities `{tools:{}}`), `notifications/initialized`, `ping`, `tools/list`, `tools/call`.

### Security
- Off by default; toggle in Settings.
- Random bearer token (32 bytes, Keychain, regenerable). Every request without
  `Authorization: Bearer <token>` → 401. Stops other local apps/web pages from reading meetings.
- Reject requests whose `Origin` header is present and not `localhost`/`127.0.0.1` (DNS
  rebinding guard, as the MCP spec requires).
- Read-only in v1: no tool writes, deletes or edits anything.

### Tools (v1)
All read from disk, so they work for the live meeting and for past ones alike.

| Tool | Args | Returns |
|---|---|---|
| `get_live_transcript` | `since?` (`"mm:ss"`, from the previous call's `next_since`) | Live meeting: stem, elapsed, only the chunks after `since`, and `next_since`. If no meeting is live: says so and names the latest meeting. |
| `list_meetings` | `limit?` (default 20) | id (stem), date, title, duration, has notes/summary, `is_live` |
| `get_meeting` | `id`, `part?` = `transcript`\|`notes`\|`summary`\|`all` (default `all`), `since?` | The requested files' text |
| `search_meetings` | `query`, `limit?` | Matching chunks with meeting id + timestamp, a few lines of context |

The cursor is a timestamp passed by the client, not state held on the server. Several clients
can read at once, and nothing resets when the app restarts. Tool descriptions tell the model:
"during a live meeting, call `get_live_transcript` with the last `next_since` before
answering". That is the copy-paste replacement.

Large outputs: cap any single result at ~60k characters. If over, return the newest part and
say how much was cut and how to page (`since`).

### Settings UI (Opus writes this)
New section **"Use in Claude & other AI apps"** (Meetings / Chat settings area, wherever
meetings settings live):
- Toggle "Allow AI apps on this Mac to read meetings" + status line (running on port …/error).
- "Copy for Claude Code" → `claude mcp add --transport http whisper-shortcut http://127.0.0.1:47823/mcp --header "Authorization: Bearer <token>"`
- "Copy for Claude Desktop" → JSON snippet for `claude_desktop_config.json` using
  `npx -y mcp-remote@<pinned> http://127.0.0.1:47823/mcp --header "Authorization:Bearer <token>"`
  (Claude Desktop config only launches stdio servers; `mcp-remote` bridges to HTTP. Needs Node.)
- "Regenerate token" (with a note that clients must be re-added).
- One line on privacy: transcripts go to whatever AI app you connect.

### Files
- `WhisperShortcut/MCP/LoopbackHTTPServer.swift`: socket accept loop on a background queue,
  minimal HTTP/1.1 parse (request line, headers, Content-Length body), response writer.
- `WhisperShortcut/MCP/MCPServer.swift`: JSON-RPC dispatch, auth/origin checks, start/stop
  bound to the setting, lifecycle in `FullApp`/app delegate.
- `WhisperShortcut/MCP/MCPMeetingTools.swift`: tool schemas + pure functions over a
  `Meetings/` URL (injectable for tests).
- Settings: new keys in `UserDefaultsKeys`, section view under `Settings/`.
- `WhisperShortcutTests/MCPMeetingToolsTests.swift`, `MCPServerTests.swift`: tool output on
  fixture files (live delta via `since`, search, caps), JSON-RPC dispatch, 401/Origin rejection.
- README `## Features`: one entry (the in-app Chat reads it).
- Xcode project: add the files to both schemes.

## Steps

1. Branch `feat/mcp-meeting-server` in a worktree of the submodule.
2. Plumbing (cheap hand: Grok 4.7, Sonnet if over cap): HTTP server, JSON-RPC, tools, tests.
3. Review: Opus checks verbatim test output and the diff.
4. Settings UI: Opus, checked in the running app with screenshots.
5. End-to-end: `rebuild-and-restart.sh`, `curl` initialize/tools/list/tools/call, then
   `claude mcp add …` in Claude Code against a real live meeting. Ask "what was just said
   about X?" twice while recording, and check that the second call only fetches the delta.
6. Claude Desktop via `mcp-remote` once.
7. Commit, push, PR (no release).

## Not in v1 (later)
- `.mcpb` Claude Desktop extension (one-click install without Node).
- Write tools (add note, fix a name in the transcript): the existing in-app tools could be exposed.
- Resources/subscriptions (push new chunks instead of polling).
- Speaker names instead of "Speaker A/B".
