# Plan — queue row 16: keep tool records of a round interrupted by Stop

## 1. What the row asks for

`ChatAgentRunner.executeToolCalls` (`WhisperShortcut/ChatAgentRunner.swift:265-366`) builds the
round's `ChatToolCallRecord`s only after its `for call in calls` loop (line 359), and `run` appends
them to `self.records` only when `executeToolCalls` returns normally (line 215-217). The only throw
inside that loop is `try Task.checkCancellation()` at the top of each iteration (line 286). So when
Stop lands while call *k* of an *n*-call round is running or awaiting approval (k < n), call k+1's
cancellation check throws and **every call of that round that already ran is dropped** from
`runner.records` — the Stop path in `ChatView.swift:1091-1105` then persists the partial reply via
`commitPartialOrRemove(… toolCalls: runner?.records ?? [])` without them, and a follow-up like
"undo that" has no event/card ID. The fix: append each call's record to `self.records` the moment
that call finishes (done, failed, denied, undeclared), and stop returning records from
`executeToolCalls`.

It does **not** ask for: making running tool handlers cancellable, changing the Stop/approval UI,
changing `commitPartialOrRemove`, changing what a record contains, or changing the model-facing
`turns` of a round.

**Falsifier wording, read precisely:** a Stop that arrives while the 2nd (last) call is running
already loses nothing today — that call finishes, the loop ends without another cancellation check,
and the round returns normally. The records are lost when Stop arrives **before the 2nd call
starts** (during call 1, or while call 1 awaits approval). The regression test and the manual check
use that scenario: 2-call round, Stop during call 1 → exactly 1 record saved. Write this reading into
`IMPLEMENTER_NOTES.md`. It is the scenario where the bug lives, not a looser falsifier.

## 2. Files to touch

- `WhisperShortcut/ChatAgentRunner.swift` — append one record per finished call to `records` inside
  the `executeToolCalls` loop; drop the `records` element from its return tuple and the
  `records.append(contentsOf: roundRecords)` line in `run`.
- `WhisperShortcut/ChatView.swift` — line 1094: extend the existing log line to
  `"CHAT: Send cancelled (partialChars=\(partialChars) toolCalls=\(runner?.records.count ?? 0))"`
  (instrumentation for the falsifier; no other change in this file).
- `WhisperShortcutTests/ChatAgentRunnerTests.swift` — three new tests (section 3).

### Exact change in `ChatAgentRunner.swift`

1. Add a private helper on `ChatAgentRunner` (next to `executeToolCalls`):
   ```swift
   /// Records one finished call right away, so a Stop later in the same round keeps it.
   private func record(_ call: (name: String, args: [String: Any], thoughtSignature: String?),
                       response: [String: Any], stepId: UUID) {
     records += ChatToolHistory.records(
       calls: [(call.name, call.args)], responses: [response], steps: [steps.step(stepId)])
   }
   ```
2. In the loop, call it at each of the three exits, with the **same** dictionary that goes into
   that call's `functionResponse.response` (today's records are built from `responseParts`, keep
   them byte-identical):
   - undeclared branch: after `steps.finish(stepId, phase: .failed, …)` — response
     `["error": "The tool \(call.name) is not available in this conversation."]`. Hoist that
     dictionary into a `let` and use it for both `responseParts.append` and `record(…)`.
   - denied branch: after `steps.finish(stepId, phase: .denied)` — same hoisting for
     `["error": "The user denied this \(call.name) call."]`.
   - normal path: after `responseParts.append([... sent.response])` — response `sent.response`.
   Call `record` **after** `steps.finish` so the step carries phase, summary and `finishedAt`
   (display fields `status`/`summary`/`durationMs`).
3. Delete `stepIds` (line 284, 290, 302) and the `roundRecords` block (lines 358-364) — no longer
   used. Change the return type to `(turns: [[String: Any]], imageMarkers: [String])` and
   `return (turns, imageMarkers)`.
4. In `run` (line 215-217): `let (turns, imageMarkers) = try await executeToolCalls(…)`; delete
   `records.append(contentsOf: roundRecords)`.
5. Update the comment on line 13-14 is already correct ("`records` still hold what the turn
   produced"); leave it. Keep the `private(set) var records` declaration as is.

## 3. Tests — `WhisperShortcutTests/ChatAgentRunnerTests.swift`

Cancel the runner from inside a handler with `withUnsafeCurrentTask { $0?.cancel() }` — handlers
are awaited inline in the runner's task, so this cancels exactly that task. Run the runner inside
its own `Task { @MainActor in try await runner.run(contents: …) }` and read `await task.result`, so
the test's own task is never cancelled. Add `"fake_create"` via `extraTools:`.

1. **Regression — "Stop mid-round keeps the calls that already ran"** (fails before, passes after):
   provider round 1 = two `.functionCall`s (`fake_lookup` args `["q":"x"]`, then `fake_create`),
   round 2 = `.textDelta("never")`. Handler `fake_lookup` cancels the current task and returns
   `ChatToolOutcome(response: ["id": "E7"])`; handler `fake_create` sets `ranSecond = true`.
   Expect: the task result is a failure whose error `is CancellationError`; `!ranSecond`;
   `runner.records.map(\.name) == ["fake_lookup"]`; `runner.records.first?.resultJSON.contains("E7")
   == true`; `runner.records.first?.status == .done`. Before the change `runner.records` is empty.
2. **"Stop while the first call awaits approval keeps its denied record"**: same two calls, but
   `fake_lookup` replaced by `remember_about_user` (in `extraTools`, needs approval, as in
   `deniedApproval`). `approve:` closure cancels the current task and returns `false` (mirrors
   `ChatView.confirmToolCall`, which answers deny on cancel). Expect CancellationError,
   `runner.records.count == 1`, `.first?.name == "remember_about_user"`, `.first?.status ==
   .denied`, the `remember_about_user` handler never ran, `fake_create` never ran.
3. **"A full multi-call round records every call once, in call order"** (guards against double
   append): round 1 = `fake_lookup` then `fake_create`, round 2 = `.textDelta("Done.")`, no
   cancellation. Expect `result.records.map(\.name) == ["fake_lookup", "fake_create"]` and
   `result.records == runner.records`.

Existing tests (`toolRoundTrip`, `undeclaredToolRefused`, `deniedApproval`, `roundCap`) must stay
green unchanged — they pin that the record content did not change.

## 4. Falsifier

- Signal: the persisted assistant message's `toolCalls` array in the session JSON, plus the log
  line `CHAT: Send cancelled (partialChars=… toolCalls=N)` added in this change. Read with
  `bash scripts/logs.sh -t 30m | grep "CHAT: Send cancelled"`.
- Manual check on the branch build: in Chat, ask for two side-effectful actions in one turn (e.g.
  "create a calendar event 'Test A' tomorrow 10:00 and one 'Test B' at 11:00"); press Stop while
  the first approval card is up or right after allowing it. Expect: the log line shows
  `toolCalls=1` (or 2 if the round completed), the stopped message keeps its tool-step group, and
  "undo that" deletes Test A by ID. Before the change the log shows `toolCalls=0`, and with no
  partial text the assistant message is removed entirely (`commitPartialOrRemove`), so Test A
  exists in Calendar but the chat has no record of it.
- Instrumentation needed on ship day: only the `toolCalls=` field above (in the file list).

## 5. Commits, in order

1. `fix(chat): keep tool records of a round interrupted by Stop`
   — `WhisperShortcut/ChatAgentRunner.swift`, `WhisperShortcutTests/ChatAgentRunnerTests.swift`
2. `chore(chat): log tool-record count when a send is cancelled`
   — `WhisperShortcut/ChatView.swift`

## 6. Traps

- Logging only via `DebugLogger`; never `print`. No new user-facing text (the change has none).
- No `AppState` involvement; do not touch it.
- Do **not** run `scripts/rebuild-and-restart.sh` — the runner owns the app lifecycle. Use the
  `xcodebuild` build + test commands from the playbook.
- No README change: no user-facing feature or shortcut changes.
- Record each call **once**: if you keep any round-level append, the multi-call test (3) fails.
- The record must use the response actually sent (`sent.response`, already capped for the model),
  then `ChatToolHistory.records` caps it again at 3 000 chars — same as today; don't pass the raw
  `response`.
- Cached (`CHAT-TOOL-REPEAT`) calls take the normal path and must be recorded too — they are today.
- `executeToolCalls` is `@MainActor` via the class; `records` mutation from inside it is fine.
- In tests, never cancel the test's own task; always wrap the runner in an inner `Task`.
- Test target imports `WhisperShortcut_AppStore` (existing `@testable import`); keep it.

## 7. Out of scope

- Cancelling an in-flight tool handler (e.g. aborting a Calendar request) — separate behaviour, risk of half-done side effects.
- Skipping the next provider round after a Stop that lands on the last call — not what the row asks; the post-loop `checkCancellation` already throws.
- Adding a `toolCalls` field to the `chatStopped` ContextLogger signal — its schema is documented in `plans/active/outcome-signals.md`, outside the allowlist; the DebugLogger line suffices.
- Changing `commitPartialOrRemove` or its placeholder copy — already handles records with empty text.
