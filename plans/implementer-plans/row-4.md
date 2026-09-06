# Row 4 — add `gemini-3.8-flash`, default Chat + Smart Improvement to it, prune 3.5/3.6 Flash from chat

Source: `plans/model-audits/2026-09-03-audit.md` → "Recommended migrations" (behavioral upgrade
+ cleanup sections, lines ~327–350). Read those two sections before starting; they carry the
prices, the probe results and the reasoning this plan compresses.

## 1. What the row asks for

Add `gemini-3.8-flash` as a new `PromptModel` **and** `TranscriptionModel` case (Stable, HTTP 200
on `:generateContent`, $0.75/$3.75, 1M/64k — identical price and limits to the 3.7 we already
ship), make it the default for **Chat** and **Smart Improvement**, hide `gemini-3.5-flash` and
`gemini-3.6-flash` from every chat-facing list by pointing their `chatReplacement` at
`gemini37Flash`, and move the two `migrateLegacyPromptRawValue` pointers that currently land on
`gemini-3.5-flash` (`"gemini-2.5-flash"`, `"gemini-3-flash-preview"`) to `gemini-3.7-flash`, so a
migration never deposits a user on a model the pickers no longer show.

It explicitly does **NOT** ask for: `gemini37Flash.chatReplacement = .gemini38Flash` (the audit's
own probe has 3.8 ~12% slower — 2958 vs 2640 ms, n=5, overlapping ranges — and that decision waits
for an interleaved latency run); removing 3.5/3.6 Flash from the **dictation** picker (the audit
says wait for transcription numbers on 3.7/3.8, and 3.6 currently holds the best glossary score in
the field); adding `gemini-3.5-transcribe`; changing the transcription, Dictate Prompt or
meeting-summary defaults; touching `migrateLegacyTranscriptionRawValue` (its 2.5-flash /
3-flash-preview pointers land on `gemini-3.5-flash`, which stays **dictation**-selectable, so
nobody ends up on a hidden model there).

## 2. Files to touch

| File | Change |
|---|---|
| `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift` | Add `case gemini38Flash = "gemini-3.8-flash"` after `gemini37Flash` (L73) plus arms in every exhaustive switch (`displayName` L~183, `shortAlias` L~253, `description` L~292, `costLevel` "Low" group L~350, `provider` `.gemini` group L~375, `geminiThinkingConfig` L~576, `asTranscriptionModel` L~625, `geminiRejectsMinimalThinking` L~764); set `ChatModelProvider.gemini.defaultChatModel = .gemini38Flash` (L28); set `SettingsDefaults.selectedChatModel` (L1798) and `selectedImprovementModel` (L1860) to `.gemini38Flash`; add `case .gemini35Flash, .gemini36Flash: return .gemini37Flash` to `chatReplacement`; repoint `"gemini-2.5-flash"` and `"gemini-3-flash-preview"` in `migrateLegacyPromptRawValue` to `Self.gemini37Flash.rawValue`; add one `DebugLogger` line in `loadChatSlotModel` where it rewrites a superseded selection; refresh the `PromptModel` header comment and the `SettingsDefaults` model-defaults comment block (L~1772, L~1856). |
| `WhisperShortcut/TranscriptionModels.swift` | Add `case gemini38Flash = "gemini-3.8-flash"` after `gemini37Flash` (L70) plus arms in `displayName` (L~120), `isRecommended` false-group (L~234), `costLevel` "Low" group (L~247), `description` (L~281), `geminiTranscriptionGenerationConfig` — join the `.gemini31Pro, .gemini37Flash` clamp arm (L~331) — and `asymmetryClass` `.geminiFlash` group (L~553); add 3.8 to the GA list in the enum header comment. |
| `WhisperShortcut/TranscriptionProvider.swift` | Add `.gemini38Flash` to the `.google` arm of `TranscriptionModel.provider` (L~128). |
| `WhisperShortcut/ChatModelCommandResolver.swift` | Add `else if normalized.contains("3.8") { candidates = [.gemini38Flash] }` immediately **before** the `"3.7"` branch (L~122); change the bare `" 3 "` branch (L~132) to `[.gemini38Flash]`; add `.gemini38Flash` to `isFlash(_:)` (L~218). |
| `WhisperShortcut/FullApp.swift` | Add one-shot `migrateChatAndImprovementDefaultsTo38Flash()` next to the existing 3.7 migrations (L~277–310) and call it in `applicationDidFinishLaunching` right after `migrateChatDefaultTo37Flash()` (L52). |
| `WhisperShortcut/UserDefaultsKeys.swift` | Add `static let didMigrateDefaultsTo38Flash = "didMigrateDefaultsTo38Flash"` after `didMigrateChatDefaultTo37Flash` (L58), with the same one-line doc comment style. |
| `WhisperShortcut/AppConstants.swift` | Point `contextDerivationEndpoint` (L433) at `gemini-3.8-flash` and update its comment — it exists to mirror the Smart Improvement default. |
| `WhisperShortcut/ChatView.swift` | In `handleModelCommand`, update the two user-visible examples `/model 3.7 flash` → `/model 3.8 flash` (L~1930, L~1938). English only. |
| `WhisperShortcutTests/ChatModelLineupTests.swift` | **New file.** Suite covering the new case, the defaults, `chatReplacement`, the migration pointers and the resolver (§3). |
| `WhisperShortcutTests/ProviderCredentialFactsTests.swift` | Add the `gemini-3.8-flash` row to `expectedEndpoints` (L~18–31) so the endpoint-template guard stays complete. |

### Two decisions the file list encodes

- **`gemini38Flash` gets 3.7's thinking treatment**, not 3.6's: `geminiThinkingConfig` returns
  `["thinkingLevel": "low"]`, `geminiRejectsMinimalThinking` returns `true`, and the transcription
  config joins the clamp arm. This is **unverified for 3.8** — say so in the code comment. 3.7,
  the model immediately before it, rejects `MINIMAL` with HTTP 400 (live-verified 2026-08-23), and
  a rejected request is a failed chat while an unnecessary `low` costs only a little latency. Do
  not run a live probe to settle it; note it for the human instead.
- **The one-shot migration is required, not optional.** `SettingsViewModel.save()` writes every
  model key on any settings change, so changing `SettingsDefaults` alone reaches almost no existing
  install — including the reviewer's, which sits on `gemini-3.7-flash` today. Without it the
  falsifier's first clause cannot pass on the branch build. Follow `migrateChatDefaultTo37Flash`
  exactly: one flag, guard on the flag, set the flag, then move **only** slots holding exactly
  `PromptModel.gemini37Flash.rawValue` (`selectedChatModel`, `selectedImprovementModel`), and
  `DebugLogger.log("MIGRATION: \(key) \(stored) → gemini-3.8-flash")` per moved key. It must run
  **after** the two 3.7 migrations so a 3.6 install chains 3.6 → 3.7 → 3.8 in one launch.

## 3. Tests

**New: `WhisperShortcutTests/ChatModelLineupTests.swift`** — `import Testing`,
`@testable import WhisperShortcut_AppStore`, `@Suite("Gemini chat lineup after 3.8")`.

1. *New case is wired* — `PromptModel.gemini38Flash.rawValue == "gemini-3.8-flash"`,
   `.provider == .gemini`, `.supportsTextChat`, `.supportsDictatePrompt`,
   `.asTranscriptionModel == .gemini38Flash`, `.shortAlias == "gemini38flash"` and unique across
   `PromptModel.allCases` (assert `Set(allCases.map(\.shortAlias)).count == allCases.count`).
2. *Defaults moved* — `SettingsDefaults.selectedChatModel == .gemini38Flash`,
   `SettingsDefaults.selectedImprovementModel == .gemini38Flash`,
   `ChatModelProvider.gemini.defaultChatModel == .gemini38Flash`, and
   `AppConstants.contextDerivationEndpoint.contains("gemini-3.8-flash")`.
3. *Prune, and only the prune the row asked for* — `PromptModel.gemini35Flash.chatReplacement ==
   .gemini37Flash`, same for `.gemini36Flash`; **`.gemini37Flash.chatReplacement == nil`** and
   `.gemini38Flash.chatReplacement == nil`. `PromptModel.chatModels` contains `.gemini37Flash` and
   `.gemini38Flash` and contains neither `.gemini35Flash` nor `.gemini36Flash`. Comment the 3.7
   assertion as the guard against the interleaved-latency decision being pre-empted.
4. *Regression — nobody is migrated onto a hidden model* (fails before the change, passes after):
   for `slug in ["gemini-2.5-flash", "gemini-3-flash-preview"]`, assert
   `migrateLegacyPromptRawValue(slug) == PromptModel.gemini37Flash.rawValue` **and** that
   `PromptModel(rawValue: migrated)!.chatReplacement == nil`. Today the first assertion returns
   `gemini-3.5-flash`; after commit 3 the second would fail on the old pointer.
5. *Resolver* — `resolve(argument:currentSelection:)` with `currentSelection: .gemini37Flash`:
   `"3.8"`, `"gemini 3.8 flash"`, `"gemini-3.8-flash"` → `.applied(model: .gemini38Flash)`;
   `"gemini 3"` → `.applied(model: .gemini38Flash)`; `"3.7"` → `.applied(model: .gemini37Flash)`
   (guards 3.8 against stealing the 3.7 query); `"3.1 flash lite"` → `.gemini31FlashLite`
   (unchanged).
6. *Transcription side* — `TranscriptionModel.gemini38Flash.provider == .google`,
   `.apiEndpoint == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent"`,
   `.asymmetryClass == .geminiFlash`, `.isSelectableForDictation == true`, and
   `geminiTranscriptionGenerationConfig(temperature: 0.0, effort: .minimal).thinkingConfig?.thinkingLevel`
   equals `TranscriptionThinkingEffort.low.geminiValue` (the clamp).

**Edited: `ProviderCredentialFactsTests.swift`** — one new `expectedEndpoints` row for
`.gemini38Flash`. No other existing test needs editing: `SettingsSlotRoundTripTests` probes the
Dictate Prompt slot with `.gemini36Flash`, which loads through `loadPromptModel` (no
`chatReplacement`), and its chat/improvement probes use `.grok43` / `.claudeSonnet5`;
`TranscriptionProviderTests.hidden.subtracting(...) == [.gemini31Pro]` still holds because 3.8 is
dictation-selectable; `TranscriptionTuningTests.everyTierCapsOutputTokens` iterates `allCases` and
the shared `.init` supplies the cap. If any of these do break, fix the test to match the intended
behaviour — do not weaken an assertion.

## 4. The falsifier — how it is read on the day this ships

| Clause | Signal | Filter |
|---|---|---|
| Chat resolves to 3.8, HTTP 200, no fallback | Existing `DebugLogger.logNetwork` in `GeminiAPIClient.streamChat` | `bash scripts/logs.sh -t 5m \| grep GEMINI-CHAT-STREAM` → expect `POST …/models/gemini-3.8-flash:streamGenerateContent` and **no** `GEMINI-CHAT-STREAM: HTTP 4xx/5xx` line |
| Smart Improvement resolves to 3.8 | Existing `ContextDerivation` L131 | `grep "USER-CONTEXT-DERIVATION: Starting context update"` → `model=Gemini 3.8 Flash provider=gemini` |
| `/model 3.8` selects it | Existing `ChatView.switchToModel` / `handleModelCommand` | `grep GEMINI-CHAT:` → `/model argument=3.8 outcome=applied(...)` then `switchToModel Gemini 3.8 Flash` |
| A profile on 3.5/3.6 Flash comes up on 3.7 | **Does not exist today — add it.** `loadChatSlotModel` rewrites the persisted value silently | New `DebugLogger.log("MODEL-LINEUP: \(key) \(loaded.rawValue) → \(replacement.rawValue) (superseded)")` in `loadChatSlotModel` before the `UserDefaults.set`. Filter: `grep MODEL-LINEUP` |
| The 3.7 → 3.8 default move actually happened on an existing install | Existing `MIGRATION:` convention | `grep "MIGRATION: selectedChatModel"` / `grep "MIGRATION: selectedImprovementModel"` → `gemini-3.7-flash → gemini-3.8-flash` |

That one `MODEL-LINEUP` line is the only instrumentation this change adds, and it is in the file
list above. `DebugLogger` only — no `print`/`NSLog`/`os_log`.

**Longer horizon** (2026-10 audit ranks 3.8 ≥ 3.7 on glossary adherence): nothing to instrument
here. That comparison is produced by `scripts/benchmark-transcription.py`, whose `MODELS` list is
**outside the allowlist** — say so in `IMPLEMENTER_NOTES.md` so the human adds `gemini-3.8-flash`
(and, if they want the baseline, `gemini-3.7-flash`) to it before the October run. Baseline to beat
is `plans/model-audits/2026-09-03-measurements.txt`.

## 5. Commits, in order

1. `feat(models): add gemini-3.8-flash to PromptModel and TranscriptionModel`
   — `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift`,
   `WhisperShortcut/TranscriptionModels.swift`, `WhisperShortcut/TranscriptionProvider.swift`,
   `WhisperShortcut/ChatModelCommandResolver.swift`
   *(enum case + every switch arm + the `"3.8"` / bare-`3` resolver branches; no default changes yet — this commit must build and test clean on its own)*
2. `feat(models): default Chat and Smart Improvement to gemini-3.8-flash`
   — `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift`,
   `WhisperShortcut/FullApp.swift`, `WhisperShortcut/UserDefaultsKeys.swift`,
   `WhisperShortcut/AppConstants.swift`, `WhisperShortcut/ChatView.swift`
3. `fix(models): hide gemini-3.5/3.6-flash from chat and forward legacy pointers to 3.7`
   — `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift`
   *(`chatReplacement`, the two `migrateLegacyPromptRawValue` pointers, the `MODEL-LINEUP` log line)*
4. `test(models): cover the 3.8 lineup, defaults, migration and /model resolution`
   — `WhisperShortcutTests/ChatModelLineupTests.swift`,
   `WhisperShortcutTests/ProviderCredentialFactsTests.swift`

`git add <path> …` explicitly on every commit — never `git add .`.

## 6. Traps

- **`DebugLogger` only.** No `print`, `NSLog`, `os_log`. Both new log lines follow the existing
  prefix convention (`MIGRATION:`, `MODEL-LINEUP:`).
- **English-only user-facing text.** `displayName` "Gemini 3.8 Flash", `description` in the same
  shape as 3.7's ("Google's Gemini 3.8 Flash • Most intelligent Flash • …"), and the two `/model`
  examples in `ChatView`.
- **Do not run `scripts/rebuild-and-restart.sh`.** That is the runner's job; an unattended run must
  not swap the user's running app. Verify with the two `xcodebuild` invocations in
  `.cursor/skills/implement-proposal/SKILL.md` §3, and do not run `scripts/run-tests.sh` (it spends
  real money on the live roundtrips).
- **No `AppState` transition is involved** — this change never leaves the settings/model layer. If
  you find yourself editing `AppState`, `SpeechService` or `MenuBarController`, you have left the
  plan; write the deviation into `IMPLEMENTER_NOTES.md` first.
- **README is not touched, and the exception is worth knowing.** `WhisperShortcut/Docs/README.md`
  is a `cp` of the repo-root `README.md` made by `scripts/rebuild-and-restart.sh` (line 50) — the
  root file is outside the allowlist, so editing only the copy creates drift the next rebuild
  reverts. This adds no user-facing feature or shortcut, so no README edit is due; the one line
  that drifts is README L94 ("Gemini 3.1 Pro and Gemini 3.7 Flash cannot run below `Low`"), plus
  its twin in `SpeechToTextSettingsTab.swift` L308 — flag both in `IMPLEMENTER_NOTES.md` rather
  than editing either.
- **Exhaustive switches have no `default:` on purpose** (`PromptModel.provider` carries a comment
  saying why). Expect the compiler to reject the first build until every arm listed in §2 is added.
  Trust `xcodebuild`, not SourceKit's transient "Cannot find type" noise.
- **Do not touch `migrateLegacyTranscriptionRawValue`.** Its `"gemini-2.5-flash"` /
  `"gemini-3-flash-preview"` → `gemini-3.5-flash` pointers are correct: 3.5 Flash stays a valid
  **dictation** choice.
- **Edge cases the tests must cover:** `gemini37Flash.chatReplacement` stays `nil` (the row's one
  explicit prohibition); the bare `" 3 "` resolver branch moves to 3.8 while `"3.7"` still resolves
  to 3.7; `shortAlias` uniqueness; the migration only moves slots sitting on exactly
  `gemini-3.7-flash`; the `.minimal` → `.low` clamp on the new transcription tier.
- **Provider request path is touched** (a new Gemini model id reaches the wire). Say so in
  `IMPLEMENTER_NOTES.md` so the human can re-run the gate with `IMPLEMENTER_LIVE_TESTS=1`, and
  flag the unverified `thinkingLevel` floor for 3.8 there too.

## 7. Out of scope

- `gemini37Flash.chatReplacement = .gemini38Flash` — the row forbids it; the audit's probe has 3.8
  slower and that call waits for an interleaved latency run.
- Hiding 3.5/3.6 Flash from the **dictation** picker — the audit wants transcription numbers for
  3.7/3.8 first, and 3.6 currently holds the field's best glossary score.
- `gemini-3.5-transcribe` — a separate audit recommendation needing a new decoder branch for
  `parts[].audioTranscription.text`.
- `scripts/test-gemini-models.sh`, `scripts/benchmark-transcription.py` — outside the allowlist
  `^(WhisperShortcut/|WhisperShortcutTests/|plans/implementer-)`; hand off in the notes.
- Root `README.md` and the stale `gpt-5.6-sol` price comment the audit flags — the first is outside
  the allowlist, the second is unrelated drift from a different provider.
- The pre-existing behaviour where `/model 3.6 flash` applies a hidden model that
  `loadChatSlotModel` forwards on the next read (same shape as `grok45` today) — untouched, since
  fixing it means changing `ChatModelCommandResolver`'s return contract for every provider.
