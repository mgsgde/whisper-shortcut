# Row 6 — incomplete WhisperKit download must read as "not downloaded"; local load/decode get a wall-clock deadline

Source: `plans/improvement-ledger.md` → I6 (usage-review 2026-09-07). Read that row before
starting; it carries the two load failures, the three cancels and the "0 offline transcriptions
after 09-03" behaviour this plan is built on.

## 1. What the row asks for

Two independent fixes on the offline-dictation path. **(A)** `ModelManager.isModelAvailable`
must return `false` for a WhisperKit model folder whose required `.mlmodelc` directories exist
but do not yet hold a compiled model — today `findFile(named:in:)` matches a directory *by name*
anywhere in the tree, so a download that was interrupted (or is still running) after Hub created
`MelSpectrogram.mlmodelc/` passes the check, `initializeModel` hands the folder to WhisperKit, and
the user gets "Unable to load model … Compile the model with Xcode" → "Model appears to be
missing or incomplete". With the fix the model reads as not downloaded, `ensureReady` resumes the
download (Hub skips files already on disk), and the load only runs on a complete folder.
**(B)** `LocalSpeechService.initializeModel` and `transcribe` run with no deadline at all
(`grep -n 'NetworkDeadline\|deadline' LocalSpeechService.swift` → nothing; I2's 60 s cap is
network-only). Bound both with a wall-clock deadline that throws the **existing retryable**
`TranscriptionError.requestTimeout` — the popup keeps its Retry button and the audio is kept —
instead of running until the user presses cancel (36.7 s / 313.7 s / 486.8 s in the ledger).

It explicitly does **NOT** ask for: new user-facing copy (the `.requestTimeout` text in
`SpeechErrorFormatter` is reused as-is — see §7); changing `requiredComponents` (Prefill stays
optional); making `WhisperKit(config)` itself cancellable; touching the streaming session, the
prewarmer's "never download mid-recording" rule, the idle-unload or memory-pressure paths;
anything about offline decode *speed* (`index.mdc` "Offline dictation speed" — the ~3 s floor is
the model, not a bug this row fixes); a README change (no feature is added or renamed).

### Claim reproduced (playbook §1b) — paste this into `IMPLEMENTER_NOTES.md`, do not re-measure

`errors-2026-09-03.log` (CEST):

```
[12:55:47.407] ERROR ❌ [LocalSpeechService.swift:97] initializeModel(_:): LOCAL-SPEECH: WhisperKit initialization failed: Unable to load model: file:///…/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-small/MelSpectrogram.mlmodelc/. Compile the model with Xcode or `MLModel.compileModel(at:)`.
[12:55:47.409] ERROR ❌ [LocalSpeechService.swift:105] initializeModel(_:): LOCAL-SPEECH: Model appears to be missing or incomplete
[12:56:18.000] ERROR ❌ [LocalSpeechService.swift:467] performWhisperTranscription(…): LOCAL-SPEECH: Transcription failed: The operation couldn't be completed. (Swift.CancellationError error 1.)
[13:25:26.973] ERROR ❌ [LocalSpeechService.swift:467] performWhisperTranscription(…): LOCAL-SPEECH: Transcription failed: The operation couldn't be completed. (Swift.CancellationError error 1.)
```

`errors-2026-08-31.log`:

```
[18:00:58.633] ERROR ❌ [LocalSpeechService.swift:55] initializeModel(_:): LOCAL-SPEECH: WhisperKit initialization failed: Unable to load model: file:///…/openai_whisper-large-v3-v20240930_turbo/TextDecoderContextPrefill.mlmodelc/. Compile the model with Xcode or `MLModel.compileModel(at:)`.
[18:00:58.634] ERROR ❌ [LocalSpeechService.swift:63] initializeModel(_:): LOCAL-SPEECH: Model appears to be missing or incomplete
```

Folder mtimes on disk today (`ls -la` under `…/whisperkit-coreml/`), which prove the load ran
**while the download was still writing**:

```
openai_whisper-small/                     MelSpectrogram.mlmodelc  Sep  3 12:55   (load failed on it 12:55:47)
                                          TextDecoder.mlmodelc     Sep  3 12:55
                                          AudioEncoder.mlmodelc    Sep  3 12:56   (landed after the failure)
openai_whisper-large-v3-v20240930_turbo/  MelSpectrogram.mlmodelc  Aug 31 17:59
                                          TextDecoder.mlmodelc     Aug 31 18:00
                                          AudioEncoder.mlmodelc    Aug 31 18:01
                                          TextDecoderContextPrefill.mlmodelc  Aug 31 18:01  (load failed on it 18:00:58)
```

Why the check passes mid-download: Hub (`swift-transformers` `HubApi.swift` → `Downloader`)
writes each file to `…/.cache/…/<name>.<etag>.incomplete` and **moves** it into place on
completion, but creates the destination *directory* first. So a final file is either absent or
complete, and the interrupted-download signature is exactly "`X.mlmodelc/` exists, its files do
not". Every `.mlmodelc` in `argmaxinc/whisperkit-coreml` (checked on disk for base, small, turbo
and via the HF tree API for tiny, medium, large-v3) contains `coremldata.bin`, `metadata.json`,
`model.mil`, `analytics/coremldata.bin`, `weights/weight.bin`; `model.mlmodel` is **not** universal
(medium has none). The 13:25 cancel on 09-03 is inside `performWhisperTranscription`, i.e. a
decode the user waited on for minutes — that is the case the decode deadline is for.

## 2. Files to touch

| File | Change |
|---|---|
| `WhisperShortcut/ModelManager.swift` | Replace `hasRequiredWhisperKitFiles(at:)` + `findFile(named:in:)` (L209–223) with `nonisolated static func incompleteComponent(at modelPath: URL) -> String?` — returns the first missing `<component>/<file>` (nil = complete); a component is complete when `modelPath/<component>` is a directory and each of `Self.compiledModelFiles = ["coremldata.bin", "model.mil", "weights/weight.bin"]` is a regular file with size > 0 (`FileManager.attributesOfItem`, `.size`). Required components (`requiredComponents`, keep the list) must be complete; `static let optionalComponents = ["TextDecoderContextPrefill.mlmodelc"]` must be complete **only if the directory exists** (absent is fine — keep the existing doc comment's reasoning, add the "present but half-written is the 08-31 case" sentence). Direct child paths only — no recursive enumerator (WhisperKit loads `modelFolder/<component>` directly, so a nested match was never loadable anyway). `isModelAvailable` (L187–190) calls it and logs `MODEL-MANAGER: \(type.displayName) folder exists but \(path) is missing or empty — download incomplete` with `logDebug` (it runs on every SwiftUI render; never `logError` here). |
| `WhisperShortcut/ModelStore.swift` | `makeReady` (L154–170): narrow the self-heal catch to `catch where healsCorruptDownloadOnLoadFailure && !Self.isCancellation(error) && !Self.isDeadline(error)`, add `nonisolated static func isDeadline(_ error: Error) -> Bool { (error as? TranscriptionError) == .requestTimeout }` next to `isCancellation` (L291). Comment: a load that ran out of time or was cancelled is not a corrupt folder; purging 1.6 GB on a slow Mac would be the prewarmer's "far too destructive" case on the dictation path. Everything else in this file stays. |
| `WhisperShortcut/WallClockDeadline.swift` | **New file** (synchronized group — no pbxproj edit). `enum WallClockDeadline` with `static func run<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T`. Exact behaviour and reference implementation in §2a. No `ContextLogger` or `DebugLogger` calls inside — callers log. |
| `WhisperShortcut/LocalSpeechService.swift` | (1) Constants: `static let modelLoadDeadline: TimeInterval = 300`, `static let decodeDeadlineFloor: TimeInterval = 60`, `static let decodeDeadlineRealtimeFactor: Double = 3`, `static func decodeDeadline(forAudioSeconds seconds: Double?) -> TimeInterval { decodeDeadlineFloor + decodeDeadlineRealtimeFactor * max(0, seconds ?? 0) }` (internal, so tests can pin them). Doc comment with the numbers: Turbo weights load in 3.7–6.1 s on an M1 Pro, `preparingMessage` promises "a few minutes" for the one-time compile, the 14-minute ANE compile is what `usesNeuralEngine` already prevents → 300 s honours the copy and still catches the pathological case; decode rtf on real recordings is 0.34–0.54 with Turbo (`plans/active/streaming-dictate.md`), large-v3 several times slower → floor + 3× audio is 4–9× the measured cost and fires only on a wedged decode, never on a long recording on a slow Mac. (2) `initializeModel` (L87–162): after the `resolveModelPath` guard add `guard ModelManager.shared.isModelAvailable(modelType) else { DebugLogger.logError("LOCAL-SPEECH: Not loading \(modelType.displayName) — its compiled model folder is incomplete; the download has to finish first"); throw TranscriptionError.modelNotAvailable(modelType) }` — this is the chokepoint every caller (prewarmer, `ensureReady`, the `transcribe` reload) goes through, so the row's two error strings can no longer be produced by a half-written folder. **The new line must not contain the substrings "missing or incomplete" or "Unable to load model"** (the falsifier greps them). Then replace `whisperKit = try await WhisperKit(config)` with a `WallClockDeadline.run(seconds: Self.modelLoadDeadline)` call whose closure builds the `WhisperKitConfig` *inside* the closure from `modelPath.path` and `encoderCompute` (both Sendable; `WhisperKitConfig` is a non-Sendable class) and returns `LoadedWhisperKit(try await WhisperKit(config))` where `private final class LoadedWhisperKit: @unchecked Sendable { let kit: WhisperKit }`; assign `whisperKit = loaded.kit` back in the actor. Add, **before** the existing generic `catch`, `catch TranscriptionError.requestTimeout { DebugLogger.logError("LOCAL-SPEECH: model load exceeded \(Int(Self.modelLoadDeadline))s wall-clock deadline for \(modelType.displayName) — aborting (LocalDeadline)"); ContextLogger.shared.logSignal(.requestTimedOut, mode: "transcription", detail: ["phase": "transcribing", "stage": "modelLoad", "timeoutSeconds": "\(Int(Self.modelLoadDeadline))", "logPrefix": "LOCAL-SPEECH", "model": modelType.rawValue]); throw TranscriptionError.requestTimeout }` and `catch is CancellationError { throw CancellationError() }` — without these two the generic catch turns them into the non-retryable `fileError("Failed to load model: …")`. (3) `transcribe` (L245–361): after `audioDuration` is known compute `let deadline = Self.decodeDeadline(forAudioSeconds: audioDuration)` and pass it to both `performWhisperTranscription` calls (the prompt-fallback retry gets its own full budget). (4) `performWhisperTranscription` (L447–490): add parameter `deadline: TimeInterval`; wrap only the `whisperKit.transcribe(audioPath:decodeOptions:callback:)` call in `WallClockDeadline.run(seconds: deadline)` (closure captures `whisperKit`, `audioURL.path`, `decodeOptions` — `DecodingOptions` and `TranscriptionResult` are Sendable in WhisperKit 1.1.0; the `!Task.isCancelled` callback comment must be updated: it now reads the deadline's work task, which is cancelled by the timer and by the caller's cancellation, so a timed-out decode stops at its next token instead of finishing on the GPU); keep the timing lines and `lastDecodeTimingsSummary = summary` **outside** the closure (actor state). Add, before the generic `catch`, `catch TranscriptionError.requestTimeout { DebugLogger.logError("LOCAL-SPEECH: decode exceeded \(Int(deadline))s wall-clock deadline (audio \(audioSecondsText)s) — aborting (LocalDeadline)"); ContextLogger.shared.logSignal(.requestTimedOut, mode: "transcription", detail: ["phase": "transcribing", "stage": "decode", "timeoutSeconds": "\(Int(deadline))", "logPrefix": "LOCAL-SPEECH", "model": currentModelType?.rawValue ?? "unknown"]); throw TranscriptionError.requestTimeout }`. Leave the existing `CancellationError` wrapping in this function as it is (today's behaviour, `DictateStreamingSession` handles both shapes). (5) Update the actor's header comment only if you add a section; do not touch the speed table. |
| `WhisperShortcutTests/ModelManagerCompletenessTests.swift` | **New file.** Suite "WhisperKit model completeness" — §3. |
| `WhisperShortcutTests/WallClockDeadlineTests.swift` | **New file.** Suite "Wall-clock deadline" — §3. |
| `WhisperShortcutTests/ModelStoreTests.swift` | Add one test to the "Ready" section — §3. |

### 2a. `WallClockDeadline.run` — behaviour and reference implementation

Why not a task group like `NetworkDeadline.data` / `SpeechService.awaitWithTimeout`: a
`withThrowingTaskGroup` body that throws still **awaits its remaining children** before the
call returns. `WhisperKit(config)` has no cancellation point while CoreML compiles (WhisperKit
1.1.0 `loadModels` never calls `checkCancellation`; `MLModel.load` is not cancellable), and a
decode only reads its cancel flag between tokens. A group would hand back the timeout only when
the stuck call returned — never, in the 14-minute ANE case. So the work runs as its own task and
whichever of work / timer / caller-cancellation settles first resumes a continuation; a result
that lands after that is dropped.

Contract (the tests in §3 pin every line):

- work finishes first → its value is returned / its error rethrown unchanged; timer cancelled.
- timer fires first → `work.cancel()`; throw `TranscriptionError.requestTimeout` **at the
  deadline**, even if the work ignores cancellation.
- the awaiting task is cancelled → `work.cancel()`, `timer.cancel()`; throw `CancellationError`
  at once, without waiting for the work.
- exactly one resume, in every interleaving, including a racer finishing before the
  continuation exists (cancellation can arrive before `withCheckedThrowingContinuation` runs).

```swift
import Foundation

enum WallClockDeadline {
  /// Serialises work, timer and cancellation onto one continuation. A racer that settles before
  /// the continuation is armed parks its result; `arm` then resumes with it immediately.
  private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var settled = false
    private var pending: Result<T, Error>?

    func arm(_ continuation: CheckedContinuation<T, Error>) {
      lock.lock()
      if let pending {
        lock.unlock()
        continuation.resume(with: pending)
        return
      }
      self.continuation = continuation
      lock.unlock()
    }

    func settle(_ result: Result<T, Error>) {
      lock.lock()
      guard !settled else { lock.unlock(); return }
      settled = true
      if let continuation {
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
      } else {
        pending = result
        lock.unlock()
      }
    }
  }

  static func run<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let once = Once<T>()
    let work = Task { try await operation() }
    let timer = Task {
      try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      work.cancel()
      once.settle(.failure(TranscriptionError.requestTimeout))
    }
    Task {
      let result: Result<T, Error>
      do { result = .success(try await work.value) } catch { result = .failure(error) }
      timer.cancel()
      once.settle(result)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in once.arm(continuation) }
    } onCancel: {
      timer.cancel()
      work.cancel()
      once.settle(.failure(CancellationError()))
    }
  }
}
```

The project is Swift 5 language mode with no warnings-as-errors; `T: Sendable` is deliberate so
the `Task` generic constraint is satisfied without relying on that (hence the
`LoadedWhisperKit` box for the non-Sendable `WhisperKit` instance).

## 3. Tests

All hermetic (no network, no model load, no `ContextLogger` writes). Swift Testing, `@testable
import WhisperShortcut_AppStore`, same shape as `NetworkDeadlineTests.swift` / `ModelStoreTests.swift`.

**`WhisperShortcutTests/ModelManagerCompletenessTests.swift`** — builds layouts in
`FileManager.default.temporaryDirectory/ModelManagerCompletenessTests-<UUID>` with a helper
`writeComponent(_ name: String, files: [String] = ["coremldata.bin", "model.mil", "weights/weight.bin"], emptyFile: String? = nil)`, and calls `ModelManager.incompleteComponent(at:)`:

1. Three complete required components, no Prefill → `nil` (available).
2. **Regression (fails before, passes after):** `MelSpectrogram.mlmodelc/` exists as an *empty
   directory* next to two complete components — the 09-03 signature → returns
   `"MelSpectrogram.mlmodelc/coremldata.bin"`. (Before the change `findFile` matched the name.)
3. `AudioEncoder.mlmodelc` has `coremldata.bin` + `model.mil` but no `weights/weight.bin` →
   returns `"AudioEncoder.mlmodelc/weights/weight.bin"`.
4. `weights/weight.bin` present but zero bytes → not complete.
5. `TextDecoderContextPrefill.mlmodelc` absent → complete; present and complete → complete;
   present as an empty directory (the 08-31 signature) → returns
   `"TextDecoderContextPrefill.mlmodelc/coremldata.bin"`.
6. A complete component nested one level deeper (`sub/AudioEncoder.mlmodelc`) with the
   top-level one missing → not complete (direct-child rule).
7. `modelPath` itself missing → returns the first required component's first file (never nil).

**`WhisperShortcutTests/WallClockDeadlineTests.swift`**:

1. **Regression for the design (fails with a task-group shape):** operation ignores
   cancellation — `for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(100)) }; return 1`
   (4 s, `try?` swallows the cancel) — `run(seconds: 0.2)` throws
   `TranscriptionError.requestTimeout` and elapsed `< 1.5 s`.
2. Fast success: `run(seconds: 5) { 42 }` returns 42, elapsed `< 1 s`.
3. The work's own error propagates unchanged: throws `TranscriptionError.noSpeechDetected` →
   `#expect(throws: TranscriptionError.noSpeechDetected)`.
4. Caller cancellation: wrap `run(seconds: 5)` around a *cooperative* 5 s sleep in a `Task`,
   sleep 50 ms, `task.cancel()` → `CancellationError`, elapsed `< 1 s`.
5. Timeout cancels the work: cooperative operation records `Task.isCancelled` (through an
   `actor Flag`) when its sleep throws; after the `requestTimeout`, wait 100 ms, flag is true.
6. Pins: `LocalSpeechService.modelLoadDeadline == 300`, `decodeDeadline(forAudioSeconds: nil) == 60`,
   `(forAudioSeconds: 10) == 90`, `(forAudioSeconds: 300) == 960`, and
   `decodeDeadline(forAudioSeconds: 0) >= NetworkDeadline.transcriptionRequestTimeout`.

**`WhisperShortcutTests/ModelStoreTests.swift`** — add to "Ready":

- "A load that timed out or was cancelled is not treated as corrupt": `heals = true`,
  `writeMarker(.small)`, `loadBehaviour = { _ in throw TranscriptionError.requestTimeout }` →
  `ensureReady(.small)` throws `TranscriptionError.requestTimeout`, `fetchCalls == 0`,
  `loadCalls == 1`, `unloadCalls.isEmpty`, `isModelAvailable(.small)` still true (files not
  purged). Repeat with `throw CancellationError()` → `CancellationError`, same counters. Keep the
  existing `selfHealIsOptIn` case untouched — it proves a `fileError` still heals.

## 4. Falsifier

Row text: on the review date, `grep -c -e 'Model appears to be missing or incomplete' -e 'Unable to load model' build/usage-review-staging/errors-*.log` = 0, and
`jq -c 'select(.kind=="cancelledWhileProcessing" and .gapMs>60000)' signals-*.jsonl` returns no
record within 5 minutes of a `LOCAL-SPEECH` error line. Baseline: 2 load failures, 3 cancels.

Both inputs exist today (`errors-*.log` via `DebugLogger.logError`, `signals-*.jsonl` via
`ContextLogger.logSignal`), so the negative side is measurable without new instrumentation. This
change adds the **positive** side that tells "the deadline fired" from "the user gave up":

- `jq -c 'select(.kind=="requestTimedOut" and .detail.logPrefix=="LOCAL-SPEECH")' signals-*.jsonl`
  — `detail.stage` is `modelLoad` or `decode`, `detail.timeoutSeconds` the cap that fired.
- `grep 'LocalDeadline' errors-*.log` — the matching error line (mirrors NetworkDeadline's
  `stalled round-trip aborted after 60s (NetworkDeadline)`).
- `bash scripts/logs.sh -t 1h | grep 'download incomplete'` — the completeness check refusing a
  half-written folder (debug level, unified log only).

The row's date (2026-09-14) has passed. Grade at the **first usage-review window after a release
carrying this is live for the operator's own build** (`AGENTS.md`: built-but-not-live is
`TOO EARLY`, never `NO EFFECT`). Blind spot to write into the notes: a cancel *below* the deadline
is invisible by design — I8 (`detail.processingMs`) is the row that makes those readable.

## 5. Commits, in order

1. `ModelManager: a .mlmodelc counts as downloaded only when its compiled files are on disk`
   — `WhisperShortcut/ModelManager.swift`, `WhisperShortcutTests/ModelManagerCompletenessTests.swift`
2. `ModelStore: a load that timed out or was cancelled is not a corrupt download`
   — `WhisperShortcut/ModelStore.swift`, `WhisperShortcutTests/ModelStoreTests.swift`
3. `LocalSpeechService: wall-clock deadline on model load and decode, surfaced as the retryable requestTimeout`
   — `WhisperShortcut/WallClockDeadline.swift`, `WhisperShortcut/LocalSpeechService.swift`,
   `WhisperShortcutTests/WallClockDeadlineTests.swift`

Commit 2 must land before 3 (3 makes `requestTimeout` reachable from `load`; without 2 the
self-heal purges the model). `git add` each path explicitly; `IMPLEMENTER_NOTES.md` stays
uncommitted.

## 6. Traps

- **Self-heal purge (the blocker).** `ModelStore.makeReady` heals *any* load error by deleting
  the folder and re-downloading. Commit 2 is not optional and not "cleanup" — without it the load
  deadline deletes a healthy 1.6 GB Turbo on a slow Mac.
- **Error mapping by string.** Both `initializeModel` and `performWhisperTranscription` classify
  errors by `localizedDescription` substrings; `TranscriptionError` is not `LocalizedError`, so
  `requestTimeout` reads as "The operation couldn't be completed. (WhisperShortcut.TranscriptionError error N.)" — no "model", no "mlmodelc" — and falls into
  the non-retryable `fileError` arm. The explicit `catch TranscriptionError.requestTimeout` must
  come **first**.
- **Falsifier strings.** No new log line may contain `Model appears to be missing or incomplete`
  or `Unable to load model` — the falsifier greps exactly those.
- **`DebugLogger` only**, never `print`/`NSLog`/`os_log`. `logError` is the only level that
  reaches `errors-*.log`; the per-render availability line must stay `logDebug`.
- **Actor isolation.** The `@Sendable` closures handed to `WallClockDeadline.run` must not touch
  `LocalSpeechService` state: build `WhisperKitConfig` inside the load closure from `String` +
  `MLComputeUnits`; assign `whisperKit`, `currentModelType`, `lastLoadedModelType`,
  `lastDecodeTimingsSummary` only after the call returns, inside the actor.
- **Abandoned work after a timeout.** A timed-out `WhisperKit(config)` keeps loading in the
  background until CoreML returns; a Retry starts a second one (transiently ~2× Turbo's RAM).
  Accepted: CoreML caches the compile, so the retry is faster, and the alternative is a load with
  no ceiling. Say so in the notes.
- **Streaming chunks.** A chunk decode that times out is a non-cancel error →
  `DictateStreamingSession.finalTranscript` returns nil → single-shot on the merged WAV with its
  own, longer, duration-scaled budget. Worst-case wait is the sum; the signal fires per timeout.
- **`ContextLogger` writes during tests** (no `isRunningTests` guard, unlike `errorFileWriter`).
  Keep `logSignal` in the two `LocalSpeechService` catch sites, never in the helper the tests
  drive.
- **Prewarmer contract unchanged.** `ConnectionPrewarmer.warmOfflineWhisper` still checks
  `isModelAvailable` and skips a model that is "not downloaded" — with the stricter check that
  now includes "download still running", which is the intended reading.
- **`TextDecoderContextPrefill.mlmodelc` stays optional** — absent is fine, half-written is not.
  Do not add it to `requiredComponents`.
- **Do not run `scripts/rebuild-and-restart.sh`** (playbook §3) — the runner owns the app
  lifecycle; verify with the two `xcodebuild` commands from the playbook. No `run-tests.sh`.
- **English only** in the new log lines; no UI text is added.
- **`IMPLEMENTER_NOTES.md` manual check:** with `whisper-base` downloaded, quit the app, delete
  `…/openai_whisper-base/MelSpectrogram.mlmodelc/weights/weight.bin`, relaunch → Settings ▸
  Transcription must show Base as *not* downloaded (no "Delete" button); select it and dictate →
  the "Downloading Whisper Base — N%" popup runs briefly (Hub fetches only the one missing file),
  then the dictation pastes. The deadline itself cannot be provoked by hand; it is covered by
  `WallClockDeadlineTests` and by the `LocalDeadline` line to grep for.

## 7. Out of scope, with reason

- `SpeechErrorFormatter` `.requestTimeout` copy says "(over 60 seconds)" and blames the internet
  connection — wrong for a local decode and for a duration-scaled cap. The row asks for the
  *existing* retryable error; new user-facing copy is a decision for Magnus. The builder writes
  this into `IMPLEMENTER_NOTES.md` under "needs a human word" and does not touch the formatter.
- `performWhisperTranscription` wrapping a user `CancellationError` into `fileError(…)` —
  pre-existing, handled by the streaming session's `isCancelled` check; a separate cleanup.
- `ModelStore.removeFiles` racing a download in flight from another task — pre-existing.
- I8's `detail.processingMs` on cancel signals — its own queue row; without it a sub-deadline
  cancel stays unreadable, which is noted as the falsifier's blind spot, not fixed here.
- Making `WhisperKit(config)` cancellable — WhisperKit 1.1.0 internals; the helper's
  drop-late-result semantics are the workaround.
- A load ceiling under "a few minutes" — would contradict `preparingMessage`'s promise and hit
  the one-time compile on slow Macs; 300 s honours the copy and still catches the 14-minute case.
