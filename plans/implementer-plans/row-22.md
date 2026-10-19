# Plan — queue row #22: hide dominated Gemini Flash tiers from dictation

## 1. What the row asks for

Take `gemini-3.5-flash`, `gemini-3.6-flash` and `gemini-3.7-flash` off the dictation pickers
(Settings → Dictate → Transcription Model, and Chat → Meeting Transcription Model). Both use
`TranscriptionModel.selectableForDictation`, which filters on `isSelectableForDictation`. Then
forward any stored selection in the two **transcription** keys
(`UserDefaultsKeys.selectedTranscriptionModel`, `UserDefaultsKeys.selectedTranscriptionModelForMeetings`):
3.6 / 3.7 Flash → `gemini-3.8-flash`, and 3.5 Flash → `gemini-3.1-flash-lite`. Evidence:
`plans/model-audits/2026-10-03-audit.md` → "Pareto check" (3.8 Flash matches or beats 3.7 and 3.6
at the same price; 3.1 Flash-Lite beats 3.5 Flash on price, leaks and glossary).

**This row does NOT:** remove any enum case (`PromptModel.asTranscriptionModel` resolves Gemini
endpoints through these cases for Dictate Prompt and Smart Improvement). It does not touch
`PromptModel`, chat (3.7 Flash stays in Chat), Dictate Prompt, Smart Improvement, the meeting
*summary* model, or `migrateLegacyTranscriptionRawValue`. That function is a raw-string alias table
for retired slugs, and these slugs still serve. It also does not touch `gemini-3.5-flash-lite`,
which is not dominated.

## 2. Files to touch

- `WhisperShortcut/TranscriptionModels.swift`: `isSelectableForDictation` (line ~192) returns
  `false` for `.gemini35Flash, .gemini36Flash, .gemini37Flash`. Extend its doc comment and the
  header comment (lines ~45–48) with one sentence each: dominated for dictation per the 2026-10-03
  audit, stored picks forwarded by `ModelSelectionReconciler.dictationForward(for:)`.
- `WhisperShortcut/ModelSelectionReconciler.swift`: add a pure `static func dictationForward(for:
  TranscriptionModel) -> TranscriptionModel?` next to `transcriptionReplacement(for:)`. In
  `reconcileTranscription(key:fallback:)`, apply it before the key check and log the rewrite.
- `WhisperShortcutTests/ModelSelectionReconcilerTests.swift`: new test (section 3).
- `WhisperShortcutTests/TranscriptionProviderTests.swift`: update the hidden-set expectation in
  `proIsNotSelectableForDictation` (it fails otherwise).

No README change. `README.md` `## Features` names no Gemini Flash tier (checked), and README is
outside the allowlist anyway.

### Exact shape of the reconciler change

```swift
/// Dictation tiers the 2026-10-03 audit found dominated (plans/model-audits/2026-10-03-audit.md,
/// "Pareto check"): hidden from the pickers via `isSelectableForDictation`, and a stored pick is
/// forwarded here. Transcription keys only — chat, Dictate Prompt and Smart Improvement keep these
/// models through `PromptModel`.
static func dictationForward(for model: TranscriptionModel) -> TranscriptionModel? {
  switch model {
  case .gemini36Flash, .gemini37Flash: return .gemini38Flash
  case .gemini35Flash: return .gemini31FlashLite
  default: return nil
  }
}
```

In `reconcileTranscription`, change `let current` to `var current`. Directly after it is computed,
before the `guard current.isGemini || …` line, insert:

```swift
if let forward = dictationForward(for: current) {
  UserDefaults.standard.set(forward.rawValue, forKey: key)
  DebugLogger.log("MODEL-RECONCILE: \(key): \(current.rawValue) → \(forward.rawValue) (dominated for dictation)")
  current = forward
}
```

The existing key check then runs on the forwarded model. A Gemini-less user on 3.7 gets forwarded
to 3.8 first and then replaced by their keyed provider, which writes a second log line. That is
correct.

Use a `switch` with `default: return nil`, not an exhaustive switch. Keep the code style of the
existing file: two-space indent, `DebugLogger` only.

## 3. Tests

`WhisperShortcutTests/ModelSelectionReconcilerTests.swift`. Add one `@Test` inside the existing
`@MainActor` suite:

`@Test("Dominated dictation tiers forward to the model that dominates them")`
- `dictationForward(for: .gemini37Flash) == .gemini38Flash`
- `dictationForward(for: .gemini36Flash) == .gemini38Flash`
- `dictationForward(for: .gemini35Flash) == .gemini31FlashLite`
- `nil` for `.gemini38Flash`, `.gemini31FlashLite`, `.gemini35FlashLite`, `.openAIGPTTranscribe`,
  `.xaiTranscribe`, `.parakeetUltra`. The last one guards against forwarding offline picks.
- Consistency loop over `TranscriptionModel.allCases`: for every model with a non-nil forward,
  `#expect(!model.isSelectableForDictation)` and `#expect(forward.isSelectableForDictation)`.
  The forward target must be offered, and nothing hidden may forward onto another hidden model.

`WhisperShortcutTests/TranscriptionProviderTests.swift`, `proIsNotSelectableForDictation`:
- Change `#expect(hidden.subtracting([.whisperMedium, .whisperLarge]) == [.gemini31Pro])` to
  `== [.gemini31Pro, .gemini35Flash, .gemini36Flash, .gemini37Flash]`. Update the comment above it
  ("Everything else stays offerable, except …") to name the three dominated Flash tiers.
- Add `#expect(!TranscriptionModel.selectableForDictation.contains(.gemini37Flash))` and
  `#expect(TranscriptionModel.selectableForDictation.contains(.gemini38Flash))`.

Do not change `ChatModelLineupTests` (it asserts that 3.7 stays in chat, which must still hold) or
`SettingsSlotRoundTripTests`. That suite round-trips `.gemini36Flash` through save and load only
and never runs the reconciler, so it keeps passing; leave it alone.

The regression this guards: before the change, `dictationForward` does not exist and the hidden
set equals `[.gemini31Pro]`, so both tests fail. After the change, both pass.

## 4. Falsifier — measurable on the day it ships

- The rewrite: `bash scripts/logs.sh -t 5m` filtered for
  `MODEL-RECONCILE: selectedTranscriptionModel: gemini-3.7-flash → gemini-3.8-flash (dominated for dictation)`.
  This is the new log line from section 2, emitted by `reconcileAll()` at launch (`FullApp.swift:92`).
- The 200 dictation: the existing line in `GeminiTranscriptionCall.swift:56`,
  `…: Using model: … (gemini-3.8-flash) at …`, with no `HTTP 4xx/5xx` error line after it.
- Chat still lists 3.7 Flash: `ChatModelLineupTests` (`PromptModel.chatModels.contains(.gemini37Flash)`)
  stays green and untouched.
- The longer-horizon benchmark is read from the 2026-11 model audit, not from app code.

No further instrumentation is needed. The only missing signal is the reconcile log line, and it is
part of this change.

How to verify by hand (copy into `IMPLEMENTER_NOTES.md`):
`defaults write <bundle-id> selectedTranscriptionModel gemini-3.7-flash`, relaunch the branch
build, then look for the log line above. The Dictate settings picker shows 3.8 Flash selected and
lists no 3.5, 3.6 or 3.7 Flash. Dictate once and look for the `Using model … gemini-3.8-flash` line.
Then open Chat → `/model` and confirm 3.7 Flash is still offered. The bundle id is in the Xcode
project. Do not guess it; read `PRODUCT_BUNDLE_IDENTIFIER`.

## 5. Commits, in order

1. `feat(dictation): hide dominated Gemini 3.5/3.6/3.7 Flash from dictation pickers`
   - Paths: `WhisperShortcut/TranscriptionModels.swift`, `WhisperShortcut/ModelSelectionReconciler.swift`,
     `WhisperShortcutTests/ModelSelectionReconcilerTests.swift`, `WhisperShortcutTests/TranscriptionProviderTests.swift`
   - Body: cite `plans/model-audits/2026-10-03-audit.md` (Pareto check) and queue row #22.

A single commit, because the hide and the forward must land together. Hiding without forwarding
would leave a stored 3.7 pick that the picker cannot display.

## 6. Traps

- **Do not put the forward in `migrateLegacyTranscriptionRawValue`.** That function is not used by
  `PromptModel`, but it is the alias table for dead slugs. Putting a live model there would also
  rewrite inside `loadSelected()` with no `MODEL-RECONCILE` line, and the falsifier would never
  fire.
- **Offline Mode:** `reconcileAll()` returns early when Offline Mode is on. The snapshot may still
  hold `gemini-3.7-flash`. `restorePreOfflineSelectionsIfNeeded()` runs before
  `reconcileTranscription`, so a restored 3.7 is forwarded in the same pass. Keep the forward
  inside `reconcileTranscription`, not in the offline branch, and do not reorder `reconcileAll`.
- **The key check runs on the forwarded model** (`var current`). Otherwise a Gemini-less user is
  replaced from the stale value, and the log would show the old model.
- The forward is idempotent: 3.8 and 3.1 Flash-Lite map to `nil`. `reconcileAll()` runs from many
  call sites, so it must not log on every call. Covered by the `nil` assertions.
- `ModelSelectionReconciler` is `@MainActor`. The new func is a plain static inside it, and the test
  suite is already `@MainActor`.
- Logging is `DebugLogger` only, never `print`. Commit only the four paths listed, never
  `git add .`. Do not run `scripts/rebuild-and-restart.sh` or `scripts/run-tests.sh`. Use the two
  `xcodebuild` gates from the playbook.
- The change has no new user-facing text. If you add any, it must be in English.
- `SettingsDefaults.selectedTranscriptionModel` is `.openAIGPTTranscribe`. It is not touched and
  not affected.

## 7. Out of scope

- Adding `gemini-3.5-transcribe` is a separate audit recommendation and a human decision.
- Chat and PromptModel lineup changes: the audit measured 3.7 vs 3.8 in chat as a tie, so 3.7 stays.
- `gemini-3.1-flash-lite` deprecation (shutdown 2027-05-07) has a revisit date in the code comment
  and is not this row.
- Stale-comment cosmetics elsewhere (`SettingsConfiguration.swift` header etc.) are outside this
  row and would only add review noise.
- README: no feature prose names these tiers, and the file is outside the allowlist.
