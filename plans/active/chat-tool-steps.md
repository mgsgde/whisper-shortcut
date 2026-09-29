# Chat Tool Steps — Show What the Agent Is Doing

**Status:** Slice 1 implemented (2026-09-29, branch `feat/chat-tool-steps`): `ChatToolSteps.swift`
(`ChatToolStep`, `ToolStepsBuffer`, `ChatToolRegistry.stepLabel` / `resultSummary`), wired into the
send loop and `executeToolCalls`; the typing indicator shows the running step, "Step N ·" and
elapsed seconds. It replaces `streamActivityBySession`. Web search is a step too. Deviation: the
elapsed clock reuses the indicator's existing 60fps `TimelineView` instead of adding a 1 s one.
**Slice 2 implemented (2026-09-29, same branch):** `ChatToolCallRecord` gained optional
`status` / `summary` / `durationMs`; labels are *derived* at render from name + `argsJSON` rather
than persisted, so records written before this slice (since 3e8af05) render too, with status and
count derived from `resultJSON`. `ChatToolStepsView.swift` renders the collapsed group; the
streaming bubble shows it live from `ToolStepsBuffer` (web search excluded there, it has no record).
Slice 3 open.
**Audience:** LLM implementing the feature end-to-end.
**Goal:** The chat stops being a black box while it works. Every tool call becomes a visible,
collapsible step; the typing indicator says which step is running and for how long; approval
for side-effectful tools happens inline in the transcript instead of in a blocking modal.

Reference pattern: the Claude apps. Tool calls are one-line collapsed rows ("Searched Gmail ·
3 results ›") that expand to details, the working state names the current step, and permission
prompts are cards in the conversation. Copy the interaction model, not the look: colors,
typography and spacing stay in `ChatTheme`.

---

## Why (what the user sees today)

- `executeToolCalls` (`ChatView.swift`) runs every call and only writes `CHAT-TOOL-*` lines to
  `DebugLogger`. Nothing appears in the transcript.
- `ChatStreamActivity` (`LLMChatProvider.swift`) has one case, `.searchingWeb`. A Gmail search,
  a calendar lookup or a 10-round Trello batch shows three pulsing dots and nothing else.
- Approval is `NSAlert.runModal()` in `confirmToolCall`, titled with the raw tool id
  ("Allow google_calendar_create_event?"). It blocks the app, can't be answered from the chat,
  leaves no trace in the transcript, and asks again for every call in a batch of ten.

## Prerequisite: persisted tool records (landed in 3e8af05)

`3e8af05` added `ChatToolCallRecord` (`ChatToolHistory.swift`) and
`ChatMessage.toolCalls`, so each assistant message keeps its tool calls (name, argsJSON,
capped resultJSON) and replays them to the model as text. **Build on that; do not add a
second store.** This spec only adds display fields (below).

---

## Slice 1 — Live step state and a talking typing indicator

**New type** (in `ChatToolHistory.swift` or a new `ChatToolSteps.swift`):

```swift
struct ChatToolStep: Identifiable, Equatable {
  let id: UUID
  let name: String
  let args: [String: String]   // flattened for labels only; never rendered raw by default
  var phase: Phase             // .awaitingApproval, .running, .done, .failed, .denied
  let startedAt: Date
  var finishedAt: Date?
  var resultSummary: String?   // "3 results", "Created", error text for .failed
}
```

**Live state lives outside the list's observation path.** Same reason as `StreamingBuffer`:
per-step updates must not invalidate the whole `ChatViewModel` / `LazyVStack` (see
`chat-freeze-investigation.md`). Add a per-session `ObservableObject` (`ToolStepsBuffer`)
held in a dictionary like `streamingBuffers`, observed only by the streaming bubble and the
typing indicator.

**Emit in `executeToolCalls`:** append a `.running` step before each call (or
`.awaitingApproval` when `requiresUserApproval`), set `.done` / `.failed` / `.denied` with
`resultSummary` after it. Memo-served repeats are `.done` with the same summary; they still
count as a step.

**Labels — one function, no per-view switches:**
`ChatToolRegistry.stepLabel(name:args:phase:) -> String`, living next to `approvalSummary`.

| Tool | Running | Done |
|---|---|---|
| `gmail_search` | Searching Gmail for "…" | Searched Gmail · N results |
| `gmail_read` | Reading email | Read "‹subject›" |
| `google_calendar_list_events` | Checking your calendar | Checked calendar · N events |
| `google_calendar_create_event` | Creating event "…" | Created event "…" |
| `google_tasks_*`, `trello_*` | same pattern: verb-ing + object | past tense + object/count |
| `read_text_file`, `list_directory`, `search_files` | Reading ‹filename› / Searching files for "…" | Read ‹filename› / N matches |
| `write_text_file`, `append_to_file`, `edit_text_file` | Writing ‹filename› | Wrote ‹filename› |
| `remember_*`, `update_app_instructions` | Saving to memory | Saved to memory |
| `generate_image` | Generating image | Generated image |
| unknown / new tool | Running ‹name with underscores → spaces› | Ran ‹…› |

Counts come from one generic helper that looks for the first array in the response
(`results`, `events`, `items`, `cards`, …) — do not hand-parse each tool. Truncate quoted
arguments to ~40 chars. Web search (`ChatStreamActivity.searchingWeb`) becomes a step with
the same shape so there is exactly one mechanism.

**Typing indicator** (`TypingIndicatorView`): shows the current step's running label, plus
elapsed seconds since the turn started once it passes 3 s ("Searching Gmail for "invoice" ·
12s"). Use `TimelineView(.periodic(from:by: 1))` scoped to the label only. With several steps
done, prefix the step number ("Step 4 · Creating task …").

**Acceptance:** during a multi-round Trello or Gmail turn, the indicator changes label per
call; no `CHAT-TOOL-*` behavior or log line changes; no new main-thread work per token.

## Slice 2 — Collapsible tool steps in the transcript

**Persist display fields** on `ChatToolCallRecord`, all `decodeIfPresent` with defaults so
old sessions load: `status` (done/failed/denied), `summary` (the done-label from Slice 1),
`durationMs`. The replay text to the model (`historyText`) does not change.

**Render** in `MessageBubbleView` for model messages with records, above the prose:

- 1 step: one row, `icon · label · ›`, e.g. "Searched Gmail · 3 results ›".
- 2+ steps: one row "Used N tools ›" (or "Used N tools · 1 failed"), collapsed by default.
- Expanded: one line per step with its label; failed steps show the error in secondary text;
  denied steps say "Denied by you". A trailing "Details" disclosure per step shows args and
  result JSON in a monospaced, horizontally scrolling block, the only place raw JSON appears.
- During streaming the same view reads from `ToolStepsBuffer`, expanded state collapsed, the
  running step marked with a small spinner. At finalize it switches to the persisted records
  with no visual jump.
- Muted palette only (`ChatTheme.secondaryText`, border opacity); failed = icon tint, not a
  red card.
- Invariant: **no SwiftUI `.textSelection` in the transcript** (hang history in
  `chat-freeze-investigation.md`). Use `SelectableProseText` if selection is needed in Details.

**v1 groups all steps above the prose.** Interleaving steps between narration paragraphs
(Claude does this) needs round boundaries inside `streamed`; defer to a later slice and note
it in Open questions.

**Acceptance:** reopen an old session: renders as before. Reopen a session made after the
change: steps show collapsed, expand works, relaunch keeps them.

## Slice 3 — Inline approval card

Replace `confirmToolCall`'s `NSAlert.runModal()` with an async approval that the transcript
answers.

- `ChatViewModel` publishes `pendingApprovalBySession: [UUID: ToolApprovalRequest]`; the
  request holds the step id, `stepLabel`, `approvalSummary` (already human-readable, with a
  content preview for file writes) and a `CheckedContinuation<ApprovalDecision, Never>`.
- The card renders at the bottom of the streaming area, above the typing indicator:
  summary text, buttons **Allow** (↩), **Deny** (Esc), and **Allow for this chat**.
- "Allow for this chat" stores the tool **name** in an in-memory per-session set; later calls
  of that tool in this session skip the card and their step shows "Allowed for this chat".
  Not persisted and not offered for tools gated for prompt-injection reasons
  (`remember_about_user`, `update_app_instructions`, `write_text_file`, `append_to_file`,
  `edit_text_file`) or for delete/archive tools. Those always ask.
- Stop / Esc-in-composer / `cancelSend` / session deletion resume the continuation with
  `.deny` so the send task never leaks. Switching sessions leaves the card waiting; the
  sidebar row shows a small "needs approval" dot.
- The decision is recorded on the step (Slice 2 shows "Denied by you" / "Allowed").
- Batch case: ten `google_tasks_complete` calls in one round show one card per call unless
  the user picks "Allow for this chat". Do not invent a batch-approve UI in this slice.

**Acceptance:** calendar create in chat shows the card inline, the app stays usable while it
waits, Deny produces the existing "The user denied this … call." response, Stop while the
card is up ends the turn cleanly.

---

## Tests (Swift Testing, `WhisperShortcutTests/`)

- `stepLabel` for every tool name returned by `ChatToolRegistry` declarations, running and
  done: never empty, never contains an underscore (catches new tools without labels).
- Result-count helper on representative responses (array under various keys, no array, error).
- `ChatToolCallRecord` decodes old JSON without the new fields; round-trips with them.
- "Allow for this chat" policy: never granted for the always-ask set.

## Out of scope

- Interleaving steps with narration paragraphs.
- Batch approval UI.
- Persisting "allow for this chat" across relaunches.
- Showing the model's hidden reasoning/thinking.

## Open questions

1. Should memo-served repeat calls appear as their own step, or fold into the previous one
   with "×2"? Default: own step (honest about what the model did); revisit if noisy.
2. Should Slice 2's Details disclosure exist at all for end users, or only in debug builds?
   Default: exists, collapsed; it is the only way to see *which* event was changed.
