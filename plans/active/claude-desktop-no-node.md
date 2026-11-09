# Claude Desktop without Node.js

**Status:** built, PR open (2026-11-05). Bridge verified against the running app (sandboxed App Store build): initialize, tools/list, tools/call. Not yet verified inside Claude Desktop itself.

## Problem

Claude Desktop only runs local MCP servers as stdio processes. Our MCP server is HTTP on
127.0.0.1, so "Connect" writes `npx mcp-remote@0.14.3 …` into `claude_desktop_config.json`.
That needs Node.js. Developers have Node but use Claude Code or Codex, which speak HTTP
directly. The people the Claude Desktop card is for are the non-developers, and they have no
Node. So the card fails for exactly its audience.

## Decision

The app binary is its own bridge. Claude Desktop starts

```
/Applications/WhisperShortcut.app/Contents/MacOS/WhisperShortcut --mcp-stdio
```

with `WHISPERSHORTCUT_MCP_URL` and `WHISPERSHORTCUT_MCP_AUTH` in `env`. In that mode
`main()` never creates the menu bar app: it reads newline-delimited JSON-RPC from stdin, POSTs
each message to the running app's `/mcp` endpoint and writes the reply to stdout.

### Why not a separate helper tool

A bundled command-line helper launched by Claude (not by us) cannot use
`com.apple.security.inherit`; it needs its own sandbox entitlements, an embedded Info.plist,
its own signing in both schemes and the App Store build. The main binary already has
`app-sandbox` + `network.client`, is signed everywhere, and needs no new target.

### Why not `.mcpb` (Claude Desktop Extensions)

One more file format to build and ship, and the user has to open a second file. The existing
"Connect" button stays one click.

## Behaviour

- One stdin line = one JSON-RPC message (object or batch). Empty lines are skipped.
- HTTP 200 → body re-serialized to one line on stdout. HTTP 202 → nothing.
- App not running / connection refused / timeout → for messages with an `id`, a JSON-RPC
  error: "WhisperShortcut is not running. Open WhisperShortcut and try again." Notifications
  get nothing.
- HTTP 401 → "WhisperShortcut's access key changed. In WhisperShortcut, open Settings → AI
  apps and click Reconnect next to Claude Desktop."
- stdout carries only JSON-RPC; diagnostics go to stderr (Claude Desktop logs stderr to
  `~/Library/Logs/Claude/mcp-server-whisper-shortcut.log`).
- stdin EOF → exit 0.

## Out of scope

- Users who connected with `npx` keep working; "Reconnect" moves them to the new entry.
- The executable path is `Bundle.main.executablePath` at connect time. Connecting from a Dev
  sidecar points Claude at the Dev build; that is acceptable for a developer.

## Verification

- Unit tests for the pure line→reply mapping and the new config shape.
- Manual: pipe an `initialize` + `tools/list` into the built binary with `--mcp-stdio`; then
  Connect in the app and call a tool from Claude Desktop with Node removed from PATH.
