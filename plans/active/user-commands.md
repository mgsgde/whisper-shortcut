# User-defined chat commands (lean version)

Status: MERGED — PR #154, `a9a0ef1` on main (2026-10-19), not in v8.46; ships with the next release. Change from the plan: the four
built-in meeting quick actions (Catch me up, Action items, Open questions, Decisions) were removed
on Magnus's word (2026-10-19: „Können wir nicht die ersten Buttons weglassen? Die werden doch so
oder so nicht genutzt."), so the meeting bar holds only user commands and is empty by default.

## Why

A setup partner configures the app for a team (a practice, an office) and wants one click that
sends a fixed, reproducible instruction to the chat model: e.g. "write a report from this meeting
transcript in our format". Today the only one-click prompts are the four hard-coded meeting quick
actions, and slash commands are hard-coded in `ChatViewModel`.

Commands, not skills: a small offline model (MLX) invokes skills unreliably; an explicit command
is a plain user turn and gives the same result every time, online or offline.

## What already works (verified in code)

- A meeting chat sends the **full transcript** (plus live notes or the summary) in the system
  instruction on every request, offline included (`buildSystemInstruction`, ChatView.swift ~1636).
  So a command only has to send its text as a user message; the model already sees the meeting.
- Quick actions send through `sendQuickAction` → `sendComposed`, the normal chat path, which
  already runs on the MLX model.

## Scope (lean)

In: one folder in app data, slash commands, meeting-bar buttons, a small Settings section.
Out (deliberately): workspace folders (`.claude/commands/` etc.) as a second source, an in-app
editor, arguments/placeholders, per-command model choice, shipping default commands.

## Design

### Storage and format

- Folder: `UserContext/commands/` (next to `system-prompts.md`, `AppSupportPaths.userContextURL()`).
  Created on first load; never written to except by "New Command" (below).
- One file per command, `<name>.md`. Name = file stem, lowercased; must match `^[a-z0-9][a-z0-9-]{0,39}$`.
- Optional frontmatter between `---` lines, `key: value`, unknown keys ignored:
  - `label` — button text (default: name with dashes as spaces, capitalised first letter)
  - `description` — autocomplete subtitle and button tooltip (default: first line of the body, cut at 80 chars)
  - `scope` — `meeting` | `chat` | `both` (default `both`)
- Body (after frontmatter, trimmed) = the prompt. Tolerates BOM and CRLF.

### Problems never crash, never hide silently

Each problem file becomes an **issue** (file name + one-line reason), shown in Settings and
logged as `USER-COMMANDS:`. Issues: invalid name, empty body, unknown `scope` value (falls back to
`both`, still loads, shown as a warning), unreadable file (EPERM etc.), file over 32 KB, name
collides with a built-in command or model alias (built-in wins, file skipped).

### Loading

`UserCommandStore.shared` (ObservableObject): `@Published commands`, `@Published issues`.
`reload()` reads the folder synchronously (a handful of small files). Called when the chat window
opens, when the app becomes active, and when the Settings section appears. No file watcher in v1:
an edit shows up the next time the window opens. That is enough for a setup partner, and it keeps
the moving parts down.

Pure, testable core: `UserCommandParser.parse(fileName:contents:reservedNames:) -> Result<UserCommand, UserCommandIssue>`.

### Running a command

- **Slash:** `/name` in the composer → sends the body as the user message. Text after the name
  (`/name focus on X`) is appended as `\n\nAdditional instructions: X`.
  Dispatch sits in `sendMessage` after the built-in commands and before model lookup misses fall
  through to a normal send.
- **Meeting button:** same send path as the built-in quick actions.
- **Scope:** `meeting` commands are buttons in the meeting bar and appear in autocomplete only in
  meeting chats; typed in a normal chat they answer with a local notice ("/x needs a meeting chat:
  it works on the transcript"). `chat` commands never get a button. `both` = both.
- **The chat shows the command, not the wall of text:** `ChatMessage` gains an optional
  `commandName: String?` (Codable, decodes `nil` for old sessions). The user bubble shows a
  `/name` chip with the label; the full instruction sits behind a "Show instruction" disclosure.
  The model still receives the full body as the user turn, so history and resends are unchanged.
- Offline: nothing special; output cap is `localPromptMaxOutputTokens` = 4096, enough for a
  one-to-two-page report.

### UI (Opus designs and writes)

1. **Autocomplete:** user commands listed after the action commands, before model aliases, with
   their description; shown from the bare `/` like action commands (they are actions).
2. **Meeting bar:** user commands with meeting/both scope as accent-tinted capsules (the built-in
   quick actions are gone, see Status); no bar at all when there are none.
   Tooltip = description. Disabled while sending, like the built-ins.
3. **Settings → Chat → "Commands"** (below the chat system prompt):
   - One row per command: `/name` monospace, label, scope badge (Meeting / Chat / Both), description.
   - Issue rows in orange with the file name and reason.
   - Empty state: one sentence on what a command is + the two buttons.
   - Buttons: **New Command…** (writes `new-command.md`, `new-command-2.md`, … from a template,
     never overwrites, then opens it in the default editor), **Open Commands Folder**, **Reload**.
   - Template is neutral (a "meeting minutes in a fixed format" example), with the frontmatter
     keys commented, so the file explains itself.

### Logging

`USER-COMMANDS: loaded N (meeting M) from <path>, issues K` on every reload;
`USER-COMMANDS: run /name (scope, N chars, via slash|button)` on each run. Never log the body.

## Work split

| Piece | Who |
|---|---|
| `UserCommand`, parser, store, reload hooks, `ChatMessage.commandName`, slash dispatch, unit tests | Grok 4.7 (`grok-build.sh`); Sonnet subagent if Grok is over the cap |
| Autocomplete rows, meeting-bar buttons, user bubble chip, Settings section, copy | Opus session |
| Review of the Grok diff, verbatim test output | Opus session |

## Tests (`UserCommandParserTests`, `UserCommandStoreTests`)

Frontmatter present/absent; defaults for label/description/scope; unknown scope → warning +
`both`; empty body; invalid name; reserved-name collision (`/new`, `/gemini`); BOM + CRLF; size
cap; store reload over a temp folder (two valid, one broken → 2 commands, 1 issue); "New Command"
never overwrites an existing file; `ChatMessage` decodes without `commandName`; argument appending.

## Done means

- `bash scripts/rebuild-and-restart.sh` exit 0, `bash scripts/run-tests.sh` green (quoted verbatim)
- Screenshots: `/anamnese` in autocomplete and its result in a meeting chat (local test file,
  not committed), the meeting-bar button, the Settings section incl. one broken file
- README `## Features`: one bullet, in its own commit
- PR open, handover to the "Whisper Deployments" session

## Open risks (outside this code)

- Quality of the offline model on a 20–30 min German conversation (~8–10k tokens of transcript).
  Measured 2026-10-19 on one synthetic case (32 runs, 4 MLX models, hand-graded): Qwen3.5 9B was
  best (about 90–95 % of facts at 25 min, about 86 % at 40 min, needs a 16 GB Mac); no run was
  error-free. A fixed "positive/negative" red-flag checklist made Qwen3-4B mark a denied symptom
  positive in 4 of 4 runs, so small models get no such checklist. Numbers spelled out as words
  flipped (47 → 77); digits, as real transcripts have them, did not. Every report needs a human
  proofread. Still to do: one real, anonymised transcript.
- Offline meeting itself (live notes/summary on MLX) is being fixed on `fix/meeting-offline-mlx`.
- The pilot's actual instruction stays out of this public repo; the setup partner drops it into
  the folder on site.
