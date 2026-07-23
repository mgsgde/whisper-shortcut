---
name: analyze-chat-freeze
description: Triage a WhisperShortcut chat-window main-thread freeze from the watchdog's on-disk hang captures and app logs — classify real vs. false-positive, localize the wedge, confirm whether the shipped fix held, and continue root-causing new variants. Use when the app beachballs/freezes/pins CPU during chat, when a new hang-*.txt appears, or when asked to investigate a chat hang.
---

# Analyze Chat Freeze

Triage a chat-window main-thread freeze from the `MainThreadWatchdog` captures and surrounding logs. The freeze presents as a beachball, ~100% CPU on the main thread, and silent logs (the wedged main thread stops draining `DebugLogger`). This skill is the diagnostic playbook; the full history and the shipped fix live in `plans/active/chat-freeze-investigation.md`.

## 1. Gather the evidence

All paths are in the sandbox Logs directory:
`~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Logs/WhisperShortcut/`

- **Captures:** `hang-<YYYYMMDD-HHMMSS>.txt` — each has a header `activity: <breadcrumb>` and a symbolicated main-thread stack. List them; default to the newest (or the `--file` the user named).
- **Daily log:** `app_<YYYY-MM-DD>.log` for the capture's date — reconstruct the timeline around the hang timestamp.
- **Live tail (if app is running):** `bash scripts/logs.sh -t 30m | grep -E 'WATCHDOG|CHAT-SEND|CHAT-LIST'` — `logs.sh -f` is a literal `CONTAINS` match, so passing the alternation to `-f` returns nothing (see `view-logs-via-bash`).

Print the scope first: which capture, its `activity:` breadcrumb, and the app version from the nearest `APP-LIFECYCLE: launched … version=` line.

## 2. Real hang or false positive?

Read the **top ~6 frames** and the breadcrumb. Known classes (do not re-investigate the false positives unless they regress):

| Top-of-stack signature | Breadcrumb | Verdict |
|---|---|---|
| `NSAlert.runModal` / `NSSavePanel.runModal` / `NSApplication runModal` | `launch` or `idle` | **False positive** — a modal event loop, not a wedge. v7.75 pings `NSModalPanelRunLoopMode`, so newer builds shouldn't capture these at all. |
| `SecItemCopyMatching` / `SecurityServer::ClientSession` / `CSSM_DecryptDataFinal` under `securityd` | `launch` **or** `chat-send streaming` | **REGRESSED — investigate.** Keychain memoization fixed the launch case, but captures on 2026-07-19 (`chat-send streaming`) and 2026-07-20 (`launch`) are both main-thread Keychain blocks. Note the breadcrumb alone does not disambiguate: a `chat-send streaming` breadcrumb with `Security` frames on top is **this** class, not the resolved SwiftUI storm below. |
| `SelectionOverlay.updateNSView` (→ `fontAttributesInRange` / `setFont:` / `_invalidateEffectiveFont`) | chat (incl. `chat-send streaming`) | **Fixed 2026-07-04 (regressed once)** — strikes even on uniform-font plain `Text` (hang-20260704-205531); invariant: **no** SwiftUI `.textSelection` anywhere in the chat transcript; selection only via `SelectableProseText` (NSTextView). (A bare `grep textSelection ChatView.swift` returns legitimate hits — the meeting-transcript view and the notice/error banners use it and are outside the transcript. Don't report those as a regression.) Self-sustaining once triggered — the circuit breaker does NOT recover it. If ambiguous vs. the streaming wedge, `sample` the live pid: SelectionOverlay frames dominating = this class. |
| `LazyVStack.placeSubviews` / `ForEach.IDGenerator.makeID` | `chat-send streaming` | **The resolved freeze** (Jul 3 stack). See §3. |
| `ScrollStateRequestTransform.findClosestSubview` | `chat-send streaming` | **The resolved freeze** (Jul 1 stack) — same storm, other hot frame. See §3. |

Any stack that ends in `GraphHost.flushTransactions → NSHostingView.beginTransaction → __CFRunLoopDoObservers` with a `chat-send streaming` breadcrumb is the streaming-layout wedge family, regardless of which SwiftUI frame is on top.

## 3. The resolved freeze — what "fixed" looks like

Root cause: the streaming bubble grew *inside* the `.scrollTargetLayout()` `LazyVStack` under `.scrollPosition(id:)`; each `StreamingBuffer` flush changed its **height**, forcing a full lazy placement pass **and** a scroll-anchor re-resolution in one non-returning AttributeGraph transaction. `StreamingBuffer` isolated render/diff but not layout height propagation, so it never cured it and throttling only shrank the window.

Fix shipped 2026-07-03 (two commits):
1. **Structural** — `ChatView.swift` `messageList` renders the streaming bubble as a plain sibling **below** the `LazyVStack`, skipped from the `ForEach` while its buffer is attached. Invariant to preserve: the streaming bubble must never be a child of the `.scrollTargetLayout()` `LazyVStack`, and `.scrollPosition` stays attached (do not toggle it per send — that resets scroll to top). Marker: `CHAT-LIST: streaming bubble detached from lazy list`.
2. **Circuit breaker** — `MainThreadWatchdog.swift` `StallCancellationRegistry`; on a `chat-send streaming` stall it cancels in-flight sends after capturing the stack. Marker: `WATCHDOG: circuit breaker cancelled N in-flight chat send(s)`.

**Confirm the fix held** (clean run): every `CHAT-SEND: start` is followed by `finalizing` → `final UI update committed` → `teardown`; the detach marker appears per send; **zero** `WATCHDOG: main thread unresponsive`; no new `hang-*.txt`. The circuit-breaker line appearing means a stall **still happened** — a regression signal, not success.

## 4. If it is a NEW real wedge

Reproduce with the recipe in `plans/active/chat-freeze-investigation.md` (4+ grounded exchanges, then Dictate→paste ~300 chars, send, scroll/switch tabs mid-stream). If instrumentation is needed, use the `debugging-workflow` skill to add `DebugLogger` breadcrumbs (right category prefix) around the suspected path, rebuild via `bash scripts/rebuild-and-restart.sh`, and re-capture. Localize using the finalize tripwires:

- `finalizing` present, `final UI update committed` absent → wedge in the **finalize render** (the one-shot streaming→final swap with grounding sources).
- Neither present during the stream → wedge in the **streaming UI updates**.

Propose the smallest change consistent with the shipped architecture — keep the streaming bubble out of the lazy/anchored layout. Rank alternatives (see the brief's candidate table) only if a minimal change can't localize the cost. Do not commit unless asked.

## Related skills

- **`view-logs-via-bash`** — the `scripts/logs.sh` flags used above.
- **`debugging-workflow`** — adding `DebugLogger` instrumentation + repro plan for a new variant.

## Anti-patterns

- Concluding "real hang" from a modal (`runModal`) stack — that's a live modal loop, not a wedge.
- Recommending more `StreamingBuffer` throttling as a fix — it treats the wrong term; the layout pass, not the flush rate, is the cost.
- Toggling / detaching `.scrollPosition` per send to "isolate" streaming — it rebuilds the ScrollView and resets scroll to top on every send.
- Trusting one watchdog sample's top frame as *the* cause — Jul 1 and Jul 3 are the same bug caught at different frames; corroborate with the breadcrumb and the log timeline.
