# MCP v2: Claude and ChatGPT configure WhisperShortcut

Status: spec (2026-10-21), nothing built. Builds on `mcp-meeting-server.md` (v1, read-only
meetings, shipped).

## Problem

The assistant the user talks to all day (Claude, ChatGPT) already knows how they write emails
and WhatsApp messages, which names and terms they use, what their work is about. WhisperShortcut
has to learn the same things again, slowly, from its own logs (Smart Improvement, Writing Style,
glossary learner). Magnus, 2026-10-21: "Claude müsste eigentlich über MCP vollen Zugriff haben
auf alles und auch in der Lage sein, auf Basis von seinem Wissen die Konfiguration zu
verbessern" and "dass WhisperShortcut nahtlos verbunden wird mit ChatGPT, Claude und so weiter."

Goal: any MCP client can read the whole user-facing configuration and change it, and one
built-in MCP prompt ("tune WhisperShortcut") lets the assistant compare the config with what it
knows about the user and propose concrete edits.

## What the assistant can change (the configuration surface)

| Area | Store today | v2 tool access |
|---|---|---|
| System prompts (Dictation, Whisper Glossary, Dictate Prompt, Chat, Read Aloud Rewrite) | `UserContext/system-prompts.md`, `SystemPromptsStore.updateSection` | read + write per section |
| Glossary / dictation terms | `GlossaryFastLearner.rememberTerm` (same as the `remember_dictation_term` chat tool) | read + add/remove |
| Writing Style profile (per context: email, messenger, work chat) | `UserContext/writing-style/profile.md` | read + write |
| User chat commands | `UserContext/commands/` (`UserCommands.swift`) | list, read, create, update, delete |
| Settings (models, toggles, languages, …) | `UserDefaults`, 97 keys in `UserDefaultsKeys` | read + write **only through a catalog** (below) |
| Smart Improvement | `ImproveFromUsageAutoRunCoordinator`, review panel | trigger a run, read history |
| Usage insights (recent interactions, failures) | `ContextLogger` JSONL | read, separate opt-in |

Never exposed: API keys, OAuth/Trello tokens, the MCP token itself, telemetry settings, the
MCP permission level (an assistant must not raise its own rights).

### Settings catalog, not raw UserDefaults
`MCPSettingsCatalog.swift`: one entry per exposed setting with key, type, allowed values (model
lists come from `PromptModel` / `TranscriptionModel` / `TTSModel`, not copies), one-line
description, and the same side effects the Settings UI triggers on save (go through
`SettingsViewModel`'s save path, not `UserDefaults.set`). Unknown key → error listing the valid
ones. This keeps the tool honest when keys are renamed, and the description doubles as the
documentation the model reads.

## Permission levels (Settings, per app, not per client)

1. **Read** (default when the server is on): everything above can be read, nothing written.
2. **Propose**: write tools stage a change. It appears in the app as a review panel (reuse
   `SmartImprovementReviewView`: diff + rationale + editable text); Accept applies, Cancel drops.
   The tool returns `{"status":"pending_review","id":…}`; `get_proposal_status(id)` tells the
   assistant what the user decided.
3. **Apply directly**: write tools apply at once. Every write goes through the existing safety
   net: `.bak` copy of `system-prompts.md`, `appendSystemPromptsHistory(source: "mcp:<client>")`
   (client name from `initialize`'s `clientInfo`), plus a new "Changes by AI apps" list in
   Settings with one-click Undo per change (the history entry keeps the previous content).

Recommendation: ship with Read as default and Propose as the suggested level. Apply directly is
for users like Magnus who would only click Accept anyway.

## Tools (v2, in addition to the four meeting tools)

Read:
- `get_configuration` — one overview: enabled features, models per mode, shortcuts (live
  bindings from `ShortcutConfig`), languages, which prompt sections are customised (lengths),
  writing style on/off, command names, permission level. The entry point; small.
- `get_system_prompt(section)` / `get_writing_style_profile` / `list_commands`,
  `get_command(name)` / `get_glossary` / `get_settings(keys?)` (catalog values + allowed values)
- `get_improvement_history(limit)` — past prompt changes with source (auto, voice-feedback, mcp)
- `get_recent_interactions(limit, mode?)` — only when "Save usage data" is on **and** a second
  toggle "AI apps may read my recent dictations" is on. Lets the assistant see real failures.

Write (behaviour depends on the permission level):
- `update_system_prompt(section, content, rationale)`
- `update_writing_style_profile(content, rationale)`
- `add_glossary_terms(terms[])`, `remove_glossary_terms(terms[])`
- `save_command(name, text)`, `delete_command(name)`
- `set_settings({key: value}, rationale)`
- `run_smart_improvement()` — starts the normal run; its result goes to the normal review panel
- `get_proposal_status(id)`

Tool descriptions say: prefer small, targeted edits; always send the full new section text (no
patches, so the review diff is exact); give a rationale the user can read in one line.

## MCP prompt: "tune WhisperShortcut"

MCP `prompts/list` + `prompts/get` (capability `prompts:{}`), one prompt `tune_whisper_shortcut`
with an optional `focus` argument (dictation, emails, messages, commands, all). The text tells
the assistant: call `get_configuration`, read the relevant sections, compare them with what you
know about the user from memory and this conversation (names, how they write emails and
messages, recurring terms, languages), then propose a short list of changes and apply them
through the write tools. In Claude Code / Claude Desktop this shows up as a slash command
(`/whisper-shortcut:tune_whisper_shortcut`); in ChatGPT the user just asks.

This is the piece that turns "Claude knows a lot about me" into a better config: the knowledge
stays in the assistant's memory, the app only offers the tools and the recipe.

## Reaching each client

| Client | How it connects | Work |
|---|---|---|
| Claude Code | HTTP on 127.0.0.1 (v1) | none |
| Claude Desktop | today `mcp-remote` (needs Node) | **`.mcpb` extension**: one file, double-click installs, no Node. Generated per install with port + token, offered as "Add to Claude Desktop" in Settings |
| Cursor, other local MCP clients | HTTP on 127.0.0.1 | copy-snippet per client in Settings |
| ChatGPT (web, desktop, mobile), claude.ai web + mobile | Their connectors call the MCP server **from the vendor's cloud**, so they need a public HTTPS URL with OAuth. 127.0.0.1 is unreachable for them. Check this against current OpenAI docs before building (developer mode / connectors change often). | **Relay** (below) |

### Relay for cloud clients (separate slice, needs a product decision)
- The app keeps an outbound WebSocket to a small relay on Cloud Run (`server/mcp-relay/`), so
  nothing on the Mac listens on the internet.
- The relay exposes `https://mcp.whispershortcut.com/u/<id>/mcp` with OAuth 2.1 (dynamic client
  registration, as ChatGPT and claude.ai expect) and forwards JSON-RPC to the app; the app runs
  the same dispatcher as the local server.
- The relay stores nothing; payloads pass through in memory. The Mac must be on and the app
  running, otherwise the tools return "WhisperShortcut is not reachable".
- Consequence to state plainly in Settings: meeting text and configuration then pass through our
  server. That is a new privacy claim and it touches `privacy.md`.
- Upside beyond ChatGPT: the same relay makes Claude and ChatGPT on the phone work with the Mac.

## Files

- `MCP/MCPServer.swift`: split dispatch into a transport-independent `MCPDispatcher` (so the relay
  reuses it), add `prompts/*`, permission check per tool, `clientInfo` capture.
- `MCP/MCPConfigTools.swift`: read/write tools, pure functions over injected stores (testable).
- `MCP/MCPSettingsCatalog.swift`: the catalog.
- `MCP/MCPProposalStore.swift`: pending proposals + status, bridged to the review panel.
- Settings: permission picker, usage-insights toggle, "Changes by AI apps" list with Undo,
  "Add to Claude Desktop" (`.mcpb`). UI written by Opus, checked in the running app.
- Tests: catalog validation (unknown key, wrong type, side effects), each write tool per
  permission level, proposal lifecycle, no secret ever in any tool output (grep test over all
  read tools with a fake Keychain), prompts/get.
- README `## Features`: one entry.

## Slices

1. **Read everything + propose prompt/glossary/writing-style changes + `tune_whisper_shortcut`
   prompt.** Smallest thing that delivers the idea in Claude Code and Claude Desktop.
2. **Apply directly + undo list, commands, settings catalog, `run_smart_improvement`.**
3. **`.mcpb` for Claude Desktop** (one click, no Node).
4. **Relay for ChatGPT, claude.ai and phones.** Only after Magnus decides on the privacy trade-off.

Plumbing per slice goes to the cheap hand (Grok 4.7, Sonnet over cap); Opus reviews against the
verbatim test output and writes the Settings UI.

## Open questions

- Relay yes/no (slice 4): data through our server vs. ChatGPT/claude.ai/mobile support.
- Do write tools need a per-client allow list ("Claude Code may write, Cursor may only read"),
  or is one level for all clients enough? v2 assumes one level.
