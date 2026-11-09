# Plan — queue row 40 (review-2026-10-21 M11: IMAP deadline idle, not total)

## 0. Premise check — the fix itself already shipped

Commit `216814e0` ("fix(mail): IMAP timeout is idle per transfer with an overall cap…", R103,
2026-10-26) already did what the row asks. In `WhisperShortcut/Mail/IMAPClient.swift`:

- `IMAPSession.idleTimeout = .seconds(20)` and `commandCap = .seconds(120)` (lines ~189–191).
- `struct Deadline { cap; idle; func next() }` returns `min(now + idle, cap)` (lines ~194–202).
- `race(before:)` calls `deadline.next()` **per single read/write** (line ~510), and every
  `fill` / `writeChunk` goes through `race`. So the idle window restarts on every chunk.

What is missing is the row's **falsifier**: the existing `slowButSteadyLiteralCompletes` test
(IMAPSessionTests.swift ~line 83) delivers its chunks instantly, so it would pass with a total
deadline too. Nothing proves the timing behaviour. This run therefore does **not** re-implement
the deadline; it makes the two durations injectable and adds the timing tests, plus one log line
that tells idle-timeouts from cap-timeouts in production. Say this plainly in
`IMPLEMENTER_NOTES.md` (premise: "already fixed in 216814e0; this run adds the proof").

## 1. What the row asks for

An IMAP command must keep running while bytes keep arriving (idle deadline reset per chunk),
fail when the server goes silent for longer than the idle window, and stop at a generous total
cap. **Not asked:** changing the 20 s / 120 s values, touching `NWIMAPTransport.open()`'s 20 s
connect timeout, changing `maxLiteralBytes`, the LOGOUT-skip logic, or any Mail tool / Chat code.

## 2. Files to touch

- `WhisperShortcut/Mail/IMAPClient.swift` — make idle/cap per-instance (init params with
  production defaults), replace the static `deadline()` with an instance method, log which limit
  fired on timeout.
- `WhisperShortcutTests/IMAPSessionTests.swift` — add `PacedTransport` and four timing tests.

Exact code changes in `IMAPClient.swift`:

1. Rename the two statics and make them internal (drop `private`) so tests can assert them:
   `static let defaultIdleTimeout: Duration = .seconds(20)` and
   `static let defaultCommandCap: Duration = .seconds(120)`. Keep their doc comments.
2. Add stored properties `private let idleTimeout: Duration` and `private let commandCap: Duration`.
3. Init becomes
   `init(transport: IMAPTransport, host: String = "", idleTimeout: Duration = IMAPSession.defaultIdleTimeout, commandCap: Duration = IMAPSession.defaultCommandCap)`
   and assigns both. Existing callers (`MailAccounts.swift:246`, all tests) stay unchanged — do
   not edit `MailAccounts.swift`.
4. Replace `private static func deadline() -> Deadline` (line ~672) with
   `private func makeDeadline() -> Deadline { Deadline(cap: ContinuousClock.now.advanced(by: commandCap), idle: idleTimeout) }`
   and change both call sites: `login` (line ~214, `readResponse(before: makeDeadline())`) and
   `run` (line ~337, `let deadline = makeDeadline()`).
5. In `race`, where it throws `IMAPError.timeout`, log once which limit fired. Compute before the
   group: `let hitsCap = limit >= deadline.cap` (`next()` returned the cap). At the early
   `if ContinuousClock.now >= limit` throw and at the final `.timedOut` branch, call
   `DebugLogger.log("IMAP: timeout limit=\(hitsCap ? "cap" : "idle")")` before throwing. Do
   **not** log for `.failed(.timeout)` coming from the transport (that is NWConnection's own).
   No host, user, or command text in this line.

## 3. Tests — `WhisperShortcutTests/IMAPSessionTests.swift`

Add a test double next to `ScriptedTransport` (same file, same style):

```swift
final class PacedTransport: IMAPTransport, @unchecked Sendable {
  // Each entry: wait `delay`, then return `data`. Empty reads list → Data() (closed).
  init(steps: [(delay: Duration, data: Data)])
  func read() async throws -> Data   // try await Task.sleep(for: delay); then pop under NSLock
  // open/write/close: no-ops; write records nothing needed.
}
```

`Task.sleep` must be the cancellable kind (it is), so the race's `cancelAll()` ends it.

Timing is scaled 1:20 from the falsifier (20 s idle → 1 s; 5 s gaps → 0.25 s; 40 s → 2 s).
Construct the session with `IMAPSession(transport:, idleTimeout: .seconds(1), commandCap: .seconds(6))`
unless stated. Mark each test with `.timeLimit(.minutes(1))`.

1. `steadyStreamOutlivesIdleWindow` — **the falsifier case, would fail with a total deadline.**
   `fetchBody(uid: 7)` where the body literal is `{16}` and arrives as: header line
   `"* 1 FETCH (UID 7 BODY[] {16}\r\n"`, then 8 chunks of 2 bytes (`"ab"`…), then
   `")\r\nA001 OK FETCH completed\r\n"`, every step delayed 0.25 s (≈2.5 s total, > 2× idle).
   Expect success and body == the 16 concatenated bytes. Also `#expect` elapsed
   (`ContinuousClock().measure`) > `.seconds(2)` so the test proves it actually streamed.
2. `silenceLongerThanIdleTimesOut` — header line at 0 s, then one step delayed 1.5 s.
   Expect `IMAPError.timeout`, and elapsed < `.seconds(1.4)` (it fired at the idle limit,
   not after the slow read finished).
3. `steadyStreamStopsAtCap` — same 0.25 s stream as case 1 but with 40 chunks (10 s) and
   `commandCap: .seconds(1.5)`. Expect `IMAPError.timeout`, elapsed < `.seconds(2.5)`.
4. `productionLimitsUnchanged` — `#expect(IMAPSession.defaultIdleTimeout == .seconds(20))`,
   `#expect(IMAPSession.defaultCommandCap == .seconds(120))`.

Keep `slowButSteadyLiteralCompletes` as is. Do not change any other existing test.

Error assertions: use the pattern already in the file (`do { …; Issue.record(...) } catch let
error as IMAPError { #expect(error == .timeout) }`).

## 4. Falsifier — where it is read

- **Primary (exactly the row's falsifier, scaled):** test cases 1 and 2 in the AppStore test-plan
  gate (`WhisperShortcutTests/IMAPSessionTests`). Case 1 fails against a total-deadline
  implementation; case 2 fails if the idle window is never enforced.
- **Production signal, available the day this ships:** the new log line, read with
  `bash scripts/logs.sh -t 7d | grep "IMAP: timeout limit="`. `limit=idle` = server went silent
  (expected, fine); `limit=cap` = a command streamed for 120 s — if that ever appears with a
  following Mail tool failure, the cap is too small. Instrumentation is item 5 in §2.

## 5. Commits, in order

1. `refactor(mail): IMAPSession takes idle timeout and command cap as init parameters` —
   `WhisperShortcut/Mail/IMAPClient.swift` (items 1–4 only; behaviour identical).
2. `feat(mail): log whether an IMAP timeout hit the idle limit or the command cap` —
   `WhisperShortcut/Mail/IMAPClient.swift` (item 5).
3. `test(mail): prove the IMAP deadline is idle per chunk with an overall cap (queue #40)` —
   `WhisperShortcutTests/IMAPSessionTests.swift`.

Each commit ends with the `Co-Authored-By` line the runner prescribes. `git add` the explicit
path only. `IMPLEMENTER_NOTES.md` stays uncommitted.

## 6. Traps

- **DebugLogger only** — no `print`, no `os_log`. Never log host/user/password/command args in
  the timeout line; `secrets` scrubbing does not cover a new interpolation.
- **No user-facing text changes.** `IMAPError.timeout`'s localized string stays as is (English,
  String Catalog key — do not edit `Localizable.xcstrings`). No README change: no feature or
  shortcut changes.
- **No AppState involvement** — this is pure Mail-layer code.
- `IMAPSession` is an `actor`; the new stored properties are `let`, so `makeDeadline()` needs no
  `await`. `Deadline` stays `Sendable`.
- `Duration` literals: `.seconds(1.5)` takes a `Double` — fine; `.milliseconds(250)` for 0.25 s.
- Timing tests are flaky if margins are tight: keep the bounds above (idle 1 s vs 0.25 s gaps
  = 4× headroom; silence 1.5 s vs 1 s idle). Do not shrink them to speed the suite up.
- Test target imports `WhisperShortcut_AppStore` — the new statics must be `internal`, not
  `private`, to be reachable via `@testable`.
- Do **not** run `scripts/rebuild-and-restart.sh` or `scripts/run-tests.sh`; use the two
  `xcodebuild` commands from the implement-proposal skill §3.
- Do not touch `NWIMAPTransport` (its `tcp.connectionTimeout = 20` and the 20 s TLS-ready
  `asyncAfter` are connect timeouts, not command deadlines).

## 7. Out of scope

- Re-implementing the idle deadline — already on main since `216814e0`.
- Tuning 20 s / 120 s — no evidence either is wrong; the new log line produces that evidence.
- Connect/TLS-handshake timeout in `NWIMAPTransport.open()` — different concern, not in the row.
- Queue row status / `plans/review-2026-10-21.md` table update — shared files outside the
  allowlist; the runner/human updates them after merge.
