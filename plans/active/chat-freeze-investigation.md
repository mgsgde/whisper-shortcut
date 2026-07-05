# Chat Main-Thread Freeze — Investigation Brief

**Status:** **Fix shipped 2026-07-03** (see [Resolution](#resolution-2026-07-03)). Monitoring for recurrence — if a new `hang-*.txt` appears with a `chat-send streaming` breadcrumb, resume via `/analyze-chat-freeze`.  
**Audience:** Strong LLM tasked with root-cause analysis and a minimal, shippable fix  
**App:** WhisperShortcut — macOS 15.5+ menu-bar app, Swift 5+, SwiftUI chat window (~4900 lines in `ChatView.swift`)

---

## Resolution (2026-07-03)

**Root cause (unified model for both real stacks):** one non-returning SwiftUI layout transaction.
The streaming bubble grew *inside* the `.scrollTargetLayout()` `LazyVStack` under `.scrollPosition(id:)`.
Each `StreamingBuffer` flush changed the bubble's **height**, which forced (a) a lazy placement pass
over the whole list — `LazyVStack.placeSubviews` / `ForEach.IDGenerator.makeID`, the **Jul 3** stack —
and (b) a scroll-anchor re-resolution — `ScrollStateRequestTransform.findClosestSubview`, the **Jul 1**
stack. Those two feed each other inside one AttributeGraph transaction that converges pathologically
slowly (Jul 1 "recovered" after 46 min) or not at all. The two captures are **two hot frames of the
same storm**, not two bugs. `StreamingBuffer` isolation only stopped *render/diff* invalidation; a
child's **height** change propagates to its container regardless of `@ObservedObject` scoping, which is
why isolation alone never fixed it and why more throttling only shrank the window.

**Fix shipped (two commits):**

1. **Structural (the cure) — `ChatView.swift` `messageList`:** render the actively-streaming bubble as a
   plain sibling *below* the `LazyVStack`, skipped from the `ForEach` while its `StreamingBuffer` is
   attached (detached only when it is `messages.last`; retry truncates the tail so that always holds).
   Its growth now only extends scroll content downward — no lazy placement, no anchor re-resolution.
   `.scrollTargetLayout()` stays on the `LazyVStack` alone; the width/padding modifiers moved to the
   wrapping `VStack`; queued rows + `listBottom` moved out with the streaming bubble to preserve order.
   Positive log marker: `CHAT-LIST: streaming bubble detached from lazy list` (in `attachStreamingBuffer`).
2. **Circuit breaker (defense-in-depth) — `MainThreadWatchdog.swift` + `ChatView.swift`:** new
   `StallCancellationRegistry` (thread-safe, lock-guarded) holds in-flight send tasks. On a stall whose
   breadcrumb starts with `chat-send streaming`, the watchdog calls `cancelAll()` after capturing the
   stack, logging `WATCHDOG: circuit breaker cancelled N in-flight chat send(s)`. This stops the network
   stream feeding a wedged bubble and, on recovery, the existing `CancellationError` path
   (`commitPartialOrRemove`) commits the partial and detaches the buffer — ending the growth loop. It
   does **not** cure a truly-infinite wedge (only the structural fix does); it bounds the slow-converge
   case and never fires in a clean run.

**Kept (now secondary):** the length-adaptive `StreamingBuffer.flushIntervalNs` throttle stays as a
frame-budget guard, no longer load-bearing for the freeze.

**Verification:** stress recipe below; success = zero `WATCHDOG: main thread unresponsive`, every
`CHAT-SEND: start` → `teardown`, no new `hang-*.txt`. The circuit-breaker line appearing means a stall
still happened (regression signal), not success.

The sections below are the **original open-investigation brief**, preserved as the diagnostic playbook
for any recurrence.

---

## Executive summary

The app intermittently **freezes** (beachball, ~100% CPU on main thread, logs go silent). The dominant real-user trigger is **chat streaming** inside a `ScrollView` + `LazyVStack` message list with `.scrollPosition(id:)`.

Multiple fix attempts since May 2026 reduced frequency and improved diagnostics, but **v7.75 (length-adaptive streaming throttle) did not eliminate the bug**. A hang was captured **today** during early streaming (~325 output tokens) in an 8-message session — stack points at **LazyVStack / ForEach placement**, not the older `findClosestSubview` path.

**Goal for analyst:** Propose the **smallest correct fix** (prefer architectural isolation over more throttling), with explicit trade-offs and a verification plan.

---

## Symptom profile

| Signal | Detail |
|--------|--------|
| UI | Beachball; process state `R`, CPU ~100% |
| Logs | Stop at wedge point; no further `DebugLogger` output from main thread |
| Recovery | Often none; user force-quits. Sometimes recovery after minutes–hours |
| Primary surface | Chat window during **streaming assistant reply** |
| Secondary (fixed/mitigated) | Keychain on main thread; SwiftUI `SelectionOverlay` loops; modal dialogs misreported as hangs |

---

## Diagnosis infrastructure (already in codebase)

### `MainThreadWatchdog.swift`

- Background queue pings main every **1 s**; **4 missed pings** → in-process Mach backtrace → `hang-<timestamp>.txt`
- Path: `~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Logs/WhisperShortcut/` (sandbox) or `~/Library/Logs/WhisperShortcut/`
- Breadcrumb via `MainThreadWatchdog.shared.note("...")` — survives main-thread wedge
- v7.75: ping posted to **common + NSModalPanelRunLoopMode** so `NSAlert.runModal` is not a false hang

### Chat send tripwires (`performSend` in `ChatView.swift`)

```
CHAT-SEND: start session=... msgs=... contentChars=... attachedImages=... inFlightSessions=...
CHAT-SEND: finalizing message sources=... supports=... contentLen=...
CHAT-SEND: final UI update committed
CHAT-SEND: teardown
```

If `finalizing` appears without `final UI update committed` → hang during **finalize render**.  
If neither appears during stream → hang during **streaming UI updates**.

---

## Hang taxonomy (14 captured files on disk)

| File | Activity breadcrumb | Verdict | Top stack |
|------|---------------------|---------|-----------|
| `hang-20260623-094004` | launch | **False positive** | `NSAlert.runModal` (Accessibility dialog) |
| `hang-20260623-111318` | launch | **False positive** | Smart Improvement review modal |
| `hang-20260623-132745` | launch | **False positive** | modal |
| `hang-20260624-091407` | — | **Fixed** | `SecItemCopyMatching` in Settings (Keychain) |
| `hang-20260624-091601` | launch | **Fixed** | Keychain + `OpenAIAPIKeySection.onAppear` |
| `hang-20260624-092002` | launch | **Fixed** | Keychain |
| `hang-20260624-093303` | launch | **Fixed** | Keychain |
| `hang-20260624-173427` | launch | **Fixed** | Keychain |
| `hang-20260629-112004` | chat-send streaming msgs=0 | **Real** | SwiftUI DisplayList / Image interpolation |
| `hang-20260629-160227` | idle | **False positive** | `NSSavePanel.runModal` (chat file attach) |
| `hang-20260701-131332` | idle | **False positive** | Live Meeting safeguard `NSAlert` (403s “recovery”) |
| `hang-20260701-134623` | chat-send streaming msgs=4 | **Real — FIXED 2026-07-03** | `ScrollStateRequestTransform.findClosestSubview` |
| `hang-20260701-152210` | idle | **False positive** | Live Meeting safeguard alert |
| `hang-20260703-093924` | chat-send streaming msgs=8 | **Real — FIXED 2026-07-03** | `ForEach` / `LazyVStack.placeSubviews` |

Full stacks for the two most important **real** hangs are appended at the end of this document.

---

## Fix history (git commits)

| Commit | Date | What |
|--------|------|------|
| `c09f09d3` | 2026-05-28 | LazyVStack + NSCache for parsed reply segments |
| `fa04fae5` | 2026-05-30 | Grounded citations: plain text markers (no inline `.link`) — SelectionOverlay |
| `10976aac` | 2026-06-01 | **Removed** `.textSelection(.enabled)` from assistant reply view entirely |
| `95879f95` | 2026-06-08 | MainThreadWatchdog + CHAT-SEND state snapshot |
| `17237105` | 2026-06-10 | ~30fps streaming throttle (pending flush dict) |
| `ed014376` | 2026-06-10 | **StreamingBuffer** — per-bubble ObservableObject, not `messages[]` |
| `52702af3` | 2026-06-10 | `scrollAnchorClearSignal` (PassthroughSubject) before list mutations |
| `698496b0` | 2026-06-10 | Removed `.id(widthBucket)` on LazyVStack |
| `04f7d3c1` | 2026-06-12 | In-process hang capture (sandbox-safe); live-summary circuit breaker |
| `7161e1a` | 2026-07-02 | **v7.75:** length-adaptive flush; watchdog modal-mode ping |

**Keychain fix** (`KeychainManager.swift`): memoize hits **and** misses — `SecItemCopyMatching` was blocking main thread from SwiftUI `.onAppear`.

---

## Current architecture (chat message list)

### Data flow during send

```
performSend()
  → appendMessage(user)           // does NOT emit scrollAnchorClearSignal
  → appendMessage(placeholder)
  → attachStreamingBuffer(id)
  → for each textDelta:
        streamingBuffer.enqueueUpdate(markerPrefix + streamed)  // length-adaptive throttle
  → finalize:
        detachStreamingBuffer
        updateStreamingMessage()  // DOES emit scrollAnchorClearSignal
```

### View hierarchy (`messageList` in `ChatView.swift`)

```
ScrollViewReader
  ScrollView
    LazyVStack
      ForEach(viewModel.messages) { message in
        MessageBubbleView(
          message,
          streamingBuffer: viewModel.streamingBuffers[message.id],  // optional
          ...
        ).id(message.id)
      }
      ForEach(messageQueue) { ... }
    .scrollTargetLayout()
  .scrollPosition(id: $scrollPositionID, anchor: .top)   // ← expensive during relayout
  .overlay { TypingIndicatorView }  // outside LazyVStack intentionally
```

### Streaming isolation (intended)

- `StreamingBuffer` (`@MainActor ObservableObject`): token writes → `@Published content` on buffer only
- `StreamingModelReplyView`: `@ObservedObject var buffer` — **observation scoped to streaming subtree**
- Comment at `ForEach` claims buffer “doesn't ripple through this ForEach” — **today's hang stack contradicts this** (ForEach/LazyVStack placement still on stack)

### Scroll anchor workaround

- `scrollAnchorClearSignal` clears `scrollPositionID` before `removeMessage`, `updateStreamingMessage`, `retryMessage`
- **Not** sent on `appendMessage` (avoids empty-list flash on send)
- Persisted anchors in UserDefaults (`chatScrollAnchors`)
- Code explicitly says: cannot detach `.scrollPosition` during streaming — “toggling rebuilds ScrollView and resets scroll to top on every send”

### Length-adaptive throttle (`StreamingBuffer.flushIntervalNs`)

```swift
case ..<4_000:  return 125_000_000  // ~8 fps
case ..<12_000: return 250_000_000  // ~4 fps
default:        return 400_000_000  // ~2.5 fps
```

Rationale in comments: each flush grows bubble → ScrollView relayout → `findClosestSubview` sweep + markdown reparse; cost scales with subview count.

### Rendering paths

- **Streaming:** `ModelReplyView(content: buffer.content, isStreaming: true)` — SwiftUI `Text` blocks, **no** `.textSelection(.enabled)`
- **Finalized prose:** `SelectableProseText` (NSTextView via `NSViewRepresentable`) — immune to SelectionOverlay bug
- **Parsed segments:** `NSCache` (`segmentCache`, `proseHeightCache`) — keyed by content hash; helps finalized bubbles, not necessarily streaming reparse every flush

---

## Critical evidence: 2026-07-03 hang (v7.75, NOT fixed)

### Context (from `app_2026-07-03.log`)

- App: **v7.75 build 173**, pid 78522 (launched 2026-07-02 13:07)
- Session `723C2265-FB4F-4AB9-BDA5-8858E2D716DF` — SAP/AI consulting topic, **4 prior grounded exchanges** (sources 6–17, supports 15–24, contentLen 2758–3905)
- User flow immediately before hang:
  1. `09:38:52` Dictate (transcription) → auto-paste
  2. `09:39:19` CHAT-SEND start `msgs=8 contentChars=346`
  3. Stream gemini-3.5-flash, tokens 2→325 in ~4s
  4. `09:39:24` WATCHDOG ≥4s, `hang-20260703-093924.txt`
  5. Stream **continues** in background to 507 tokens, stream end `09:39:25`
  6. **No** `finalizing`, **no** `teardown`
  7. `09:40:27` Force quit → relaunch pid 12206

### Interpretation

- Hang is **during streaming UI**, not finalize
- Occurred at **short** reply length (~325 chars) — length-adaptive throttle still at fastest tier (~8fps)
- Session history (8 msgs, heavy grounded bubbles above) likely dominates layout cost
- Stack: **LazyVStack placement / ForEach ID generation**, not `findClosestSubview` — may be same underlying relayout pressure, different hot frame

---

## Critical evidence: 2026-07-01 hang (motivated v7.75)

### Context

- Session `117C1479...`, `msgs=4`, streaming grounded reply
- `13:46:23` watchdog capture → `hang-20260701-134623.txt`
- Stack: **`ScrollStateRequestTransform.findClosestSubview`**
- Recovery logged `16:07:58` — **2752 s** later (46 min); no `finalizing` logged for that send in the interim

### Interpretation

- Classic `.scrollPosition(id:)` + streaming relayout wedge
- v7.75 length-adaptive throttle was meant to fix this — **partially effective at best** (shorter hang window? still happened Jul 3 with different stack)

---

## Resolved hang classes (do not re-investigate unless regressed)

### SelectionOverlay (`setFont:` / `_invalidateEffectiveFont` loop)

- Trigger: `.textSelection(.enabled)` on SwiftUI `Text` with per-run markdown fonts or inline `.link`
- Fixed: plain citation markers; removed selection from `ModelReplyView`; tables not selectable
- Files: `ChatView.swift` (`ModelReplyView`, `citationMarker`), `MarkdownParsing.swift`
- **REGRESSED 2026-07-04 via the user bubble** (`hang-20260704-205531.txt`, v7.76, `chat-send
  streaming`): the user-bubble `Text` had kept `.textSelection(.enabled)` under a "safe: single
  uniform-font Text" assumption. A live `sample` of the wedged pid (97% CPU, 25+ min) showed the
  loop is **not** limited to mixed-font runs: `SelectionOverlay.updateNSView` → `setFont:` →
  `_invalidateEffectiveFont` → `invalidateIntrinsicContentSize` → next transaction, forever, on
  plain single-font German text — streaming layout churn merely kicks it off, after which it is
  fully self-sustaining (survived the circuit breaker cancelling the send; the breaker only helps
  the layout-storm class). Each pass also re-ran lazy placement + ScrollView sizing, so the
  capture's tail mimicked the streaming-wedge family — corroborate with a live sample, not one
  watchdog stack. Fixed 2026-07-04: removed `.textSelection` from the user bubble
  (`MessageBubbleView.bubbleContent`); full-message copy remains via `userCopyButtonRow`.
- **Invariant: no SwiftUI `.textSelection` anywhere in the chat transcript, uniform font or
  not.** Use `SelectableProseText` (NSTextView) where selection is required. Settings/onboarding
  windows are exempt (no layout churn).

### Keychain on main thread

- Fixed: `KeychainManager` full cache including absent accounts
- Evidence: `hang-20260624-*` stacks through `SecItemCopyMatching` under `_AppearanceActionModifier`

### Watchdog false positives (modals)

- Fixed: CFRunLoop modal mode ping (v7.75)
- Do not treat `activity: idle` + `NSAlert.runModal` / `NSSavePanel` as product freezes

---

## Open hypotheses (ranked for analyst)

1. **StreamingBuffer flush still invalidates LazyVStack** despite isolation — `@Published content` on `StreamingModelReplyView` may still trigger `ForEach`/`LazyVStack` placement for the whole list when bubble height changes, especially with `.scrollPosition(id:)` + `.scrollTargetLayout()`.

2. **`.scrollPosition(id:)` is the multiplier** — every bubble height change runs scroll-anchor resolution over visible subviews; cost grows with **session message count** and **complexity of prior bubbles** (grounded sources chips, NSTextView heights, tables).

3. **Markdown parse on every flush during streaming** — `ModelReplyView` rebuilds blocks from raw string each flush; `segmentCache` may not apply to streaming path or cache key churns.

4. **ForEach identity / `streamingBuffers` dictionary** — passing `viewModel.streamingBuffers[message.id]` into `MessageBubbleView` may cause broader invalidation than intended when buffer object identity or parent reads change.

5. **Dictate→paste→send race** — less likely primary cause (hang mid-stream after stable send start), but composer/clipboard updates concurrent with stream_start.

6. **Non-converging AttributeGraph transaction** — single runloop observer never completes (debugging-workflow skill: all samples in one transaction, no event wait).

---

## Approaches already considered in code comments (constraints)

| Idea | Why not done (per code) |
|------|-------------------------|
| Detach `.scrollPosition` while streaming | Rebuilds ScrollView; scroll jumps to top on every send |
| Faster throttle only | Jul 1 hang at ~8fps fixed rate; Jul 3 at ~8fps tier still hung early |
| Per-token writes to `messages[]` | Caused LazyVStack diff every token (removed in StreamingBuffer commit) |
| `scrollAnchorClearSignal` on append | Caused empty-list flash on send |
| `.textSelection` on streaming text | SelectionOverlay 100% CPU hang |

---

## Candidate fix directions (for analyst to evaluate)

**Prefer solutions that decouple streaming UI from the historical LazyVStack.**

| # | Approach | Pros | Cons |
|---|----------|------|------|
| A | **Streaming overlay** — render active stream outside LazyVStack (fixed bottom overlay, only finalized messages in list) | Isolates relayout to one view | Scroll/sync complexity; tool-call multi-bubble? |
| B | **Disable `.scrollPosition` during stream** — save offset manually, restore after | Directly removes findClosestSubview | Code says scroll jumps; need proof offset can be preserved another way |
| C | **Plain-text streaming** — no markdown parse until finalize | Cheap flushes | Ugly streaming UX |
| D | **Hard virtualization** — AppKit `NSTableView` / `NSCollectionView` for messages | Proven perf | Large rewrite |
| E | **EquatableView / identity stabilization** on `MessageBubbleView` | Small diff | May not be enough if layout is extrinsic (height changes) |
| F | **Throttle as function of session message count**, not just stream length | Tiny diff | More latency; may not fix ForEach placement wedge |
| G | **Watchdog circuit breaker** — on ≥4s stall, cancel stream + commit partial + detach scrollPosition | Prevents force-quit | Doesn't fix root cause; degraded UX |

---

## Key source files

| File | Role |
|------|------|
| `WhisperShortcut/ChatView.swift` | StreamingBuffer, performSend, messageList, ModelReplyView, MessageBubbleView |
| `WhisperShortcut/MainThreadWatchdog.swift` | Hang capture |
| `WhisperShortcut/KeychainManager.swift` | Keychain cache (fixed class) |
| `WhisperShortcut/MarkdownParsing.swift` | Table rendering; SelectionOverlay notes |
| `WhisperShortcut/ChatSessionStore.swift` | Session persistence |
| `.cursor/skills/debugging-workflow/SKILL.md` | Hang debugging protocol (`sample`, CPU state) |

---

## Reproduction recipe (most reliable)

1. Open chat; run **4+ exchanges** with **grounded/web search** replies (long markdown, sources chips).
2. Use **Dictate** → auto-paste into chat (or type a ~300-char message).
3. Send; let **streaming** run (do not wait for finalize).
4. Optionally switch chat tabs mid-stream (historically worsened SelectionOverlay; may still stress layout).

**Success criteria for fix:** No watchdog capture ≥4s during 10-minute stress session; `CHAT-SEND: teardown` always follows start; UI stays responsive at ~100% stream duty.

---

## Verification plan (post-fix)

1. `bash scripts/rebuild-and-restart.sh`
2. Reproduce recipe above on debug build
3. `bash scripts/logs.sh -f 'WATCHDOG|CHAT-SEND' -t 30m`
4. Confirm no new `hang-*.txt` in Logs directory
5. Regression: scroll position persists across tab switch / relaunch; no empty-list flash on send; finalized prose still selectable via NSTextView

---

## Appendix A — Full stack: hang-20260703-093924.txt

```
activity: chat-send streaming session=723C2265-FB4F-4AB9-BDA5-8858E2D716DF msgs=8

 0  libsystem_malloc.dylib _xzm_free
 1  libswiftCore.dylib ArrayBuffer iterator resume
 2  SwiftUICore ForEach.IDGenerator.makeID
 3  SwiftUICore ForEachState.item(at:offset:)
 4  SwiftUICore ForEachState.forEachItem
 5  SwiftUICore ForEachList.applyNodes
 6  SwiftUICore _LazyLayout_Subviews.applyNodes
 7  SwiftUICore LazyVStack.placeSubviews
 8  SwiftUICore LazySubviewPlacements.placeSubviews
 9  SwiftUICore LazySubviewPlacements.updateValue (LazyVStackLayout)
10  AttributeGraph Graph::UpdateStack::update
11  AttributeGraph Subgraph::update
12  SwiftUICore GraphHost.flushTransactions
13  SwiftUI NSHostingView.beginTransaction
14  SwiftUICore ViewGraphRootValueUpdater.updateGraph
15  CoreFoundation __CFRunLoopDoObservers
16  AppKit -[NSApplication run]
```

## Appendix B — Full stack: hang-20260701-134623.txt

```
activity: chat-send streaming session=117C1479-5FA1-444B-BF40-B1C797A19DF1 msgs=4

 0  SwiftUICore Element.forEach (ViewTransform)
 1  SwiftUICore ViewTransform.forEach
 2  SwiftUICore _LazyLayoutViewCache.withPlacementData
 3  SwiftUICore LazyScrollable.forEachVisibleSubview
 4  SwiftUICore ScrollStateRequestTransform.findClosestSubview   ← scrollPosition
 5  SwiftUICore ScrollStateRequestTransform.updateValue
 6  AttributeGraph Graph::UpdateStack::update
 7  SwiftUICore GraphHost.flushTransactions
 8  SwiftUI NSHostingView.beginTransaction
 9  CoreFoundation __CFRunLoopDoObservers
10  AppKit -[NSApplication run]
```

## Appendix C — Log excerpt: Jul 3 hang timeline

```
[09:37:37] CHAT-SEND: finalizing ... contentLen=3905 sources=14 supports=24  (prior turn OK)
[09:37:37] CHAT-SEND: final UI update committed
[09:37:37] CHAT-SEND: teardown
[09:39:19] CHAT-SEND: start ... msgs=8 contentChars=346
[09:39:19] CHAT-LIST: append role=user count=9
[09:39:19] CHAT-LIST: append role=model count=10
[09:39:19] GEMINI-CHAT-STREAM: POST gemini-3.5-flash:streamGenerateContent
[09:39:20..23] GEMINI-CHAT-STREAM: output 2→325 tokens
[09:39:24] WATCHDOG: main thread unresponsive ≥4s (activity: chat-send streaming ... msgs=8)
[09:39:24] WATCHDOG: hang stack written to hang-20260703-093924.txt
[09:39:25] GEMINI-CHAT-STREAM: stream end output=507 (network continued; UI wedged)
[09:40:27] APP-LIFECYCLE: launched pid=12206 version=7.75  (user force quit)
```

---

## Prompt to paste into analyst LLM

```
You are analyzing a macOS SwiftUI main-thread freeze in WhisperShortcut's chat window.

Read the investigation brief at:
  whisper-shortcut/plans/active/chat-freeze-investigation.md

Then read these source files:
  - WhisperShortcut/ChatView.swift (StreamingBuffer, messageList, performSend, ModelReplyView, MessageBubbleView)
  - WhisperShortcut/MainThreadWatchdog.swift

Hang captures on disk (full stacks in brief appendices):
  ~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Logs/WhisperShortcut/hang-20260703-093924.txt
  ~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Logs/WhisperShortcut/hang-20260701-134623.txt

Deliver:
1. Root cause — unify the Jul 1 (findClosestSubview) and Jul 3 (LazyVStack/ForEach) stacks into one model if possible.
2. Minimal fix — concrete Swift/SwiftUI changes with file/line targets; explain why StreamingBuffer isolation failed.
3. Trade-offs — scroll position, UX, streaming formatting.
4. Verification — step-by-step repro + log markers proving fix.
5. Alternatives ranked if minimal fix is insufficient.

Constraints: KISS; English UI strings; no print/NSLog (DebugLogger only); must work in App Sandbox; prefer not rewriting entire chat UI unless necessary.
```
