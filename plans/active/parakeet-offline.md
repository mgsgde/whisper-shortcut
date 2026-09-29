# Parakeet Ultra as the offline dictation engine

**Status:** D1–D3 approved as recommended (Magnus, 2026-09-29: „Ja, passt so, fang mit Slice 1 an"). S1 built on `feat/parakeet-s1` (`9d6a7f4`), not merged: app path measured 0.12 s for a 4.7 s sentence, 0.69 s for 75 s, first load 0.48 s; loads run with FluidAudio's `ModelHub.offlineMode` on; Release App Store build + `codesign --verify --deep --strict` pass (NemoTextProcessing links statically, no embedded framework). Next: S2. Improvement
plan row: `plans/improvement-plan-2026-09.md` F15 (second half). Supersedes queue row 18 (Whisper
glossary on >30 s audio) for everyone who switches.
**Why now:** the Arztpraxis pilot rolls out offline from 2026-10-15; today's offline dictation
makes the user wait ~2 s after every short dictation and ~10 s after a long one.

## Evidence

`benchmarks/local-asr/README.md` → Results (2026-09-29, M1 Pro, 65 clips: 10 synthetic practice
dictations, 55 of the user's own recordings scored against the cloud transcript):

| | WER real | WER synth | practice terms | wait, <5 s clip | wait, >30 s clip | warm load |
|---|---:|---:|---:|---:|---:|---:|
| Whisper large-v3 turbo (today) | 8.4 % | 4.7 % | 19/24 | 1.89 s | 10.1 s | 4.6 s |
| Whisper turbo + glossary (today) | 19.3 % | 9.8 % | 24/24 | 3.40 s | 13.7 s | 4.6 s |
| **Parakeet Ultra** | **8.1 %** | 5.8 % | 18/24 | **0.10 s** | **0.46 s** | 0.4 s |
| **Parakeet Ultra + CTC vocabulary** | 8.3 % | **3.7 %** | **23/24** | 0.27 s | 1.54 s | 0.7 s |

Rejected on the same run: Parakeet v3 (10.8 % real), Redux (worse, its ANE compile fails on M1
and every load takes 32 s), Apple `SpeechTranscriber` (12.2 % real, 14/24 terms,
`contextualStrings` has no effect).

## Target behaviour

- A new offline model **"Parakeet Ultra (Offline)"** sits in the same "Available Models" list as
  the Whisper models, downloads like them (~730 MB: Ultra ~630 MB + CTC 110M ~100 MB, one row,
  one progress bar), and is selectable for Dictation, Meetings and Dictate Prompt's local path
  exactly where Whisper is today.
- With it selected, the wait after Stop is the decode of the whole recording: ~0.1 s for a
  sentence, ~0.5 s for a minute.
- The **Glossary** keeps working: its terms become Parakeet's vocabulary (CTC boosting) instead of
  Whisper `promptTokens`. Same editor, same "Add Selection to Glossary", same 1 200-char budget.
- Whisper stays, unchanged, for languages outside Parakeet's 25 and for anyone who prefers it.
- Offline Mode guarantees are unchanged: after the download, nothing touches the network.

## Design

**One offline store, not a second one.** `OfflineModelType` gains `.parakeetUltra` and
`TranscriptionModel` gains `.parakeetUltra` (`provider == .offline`). Everything that iterates
offline models (Settings list, `ModelDownloadRow`, reconciler, onboarding readiness, Offline Mode
card, credential checks, error copy) then picks it up without new UI. A second `ModelStore`
subclass would duplicate all of that for no gain.

**Engine split behind `LocalSpeechService`.** Callers keep calling
`LocalSpeechService.shared.transcribe(audioURL:language:prompt:)`; the actor routes on
`OfflineModelType.engine` (`.whisperKit` / `.parakeet`). The Parakeet path lives in a new
`ParakeetBackend.swift` (FluidAudio `AsrManager` + `VocabularyBoostingSession`), so the WhisperKit
code and its long doc comment stay as they are. Shared: silence gate, idle unload, memory-pressure
unload, wall-clock deadlines, `TextProcessingUtility` normalisation, `SPEED:` log lines (tagged
with the engine).

**Files on disk.** `AppSupport/WhisperShortcut/Parakeet/` via `AsrModels.download(to:)` and
`CtcModels.download(to:)` — inside the container, next to `WhisperKit/`, deletable from the row.
`ModelManager.resolveModelPath` / `isModelAvailable` switch on engine; completeness uses
`AsrModels.modelsExist(at:version: .ultra)` plus the CTC directory. **Load only from a complete
directory**: FluidAudio's `ModelHub.loadModels` silently re-downloads missing files, which would be
a network call at dictation time in Offline Mode.

**Glossary → vocabulary.** Parse the Glossary section into terms (split on commas and newlines,
drop a leading `Terms:`, trim, drop < 3 chars — FluidAudio's `minTermLength`). Build the
`VocabularyBoostingSession` once per glossary text and cache it; rebuild on change. Empty glossary →
no CTC pass at all (the unboosted path is 0.1 s instead of 0.27 s). The section key stays
`whisperGlossary` (stored files, Smart Improvement, chat tools all use it); only user-facing copy
that says "Whisper Glossary" / "conditioning text for offline Whisper" changes to engine-neutral.

**Language.** Pass the `whisperLanguage` setting as FluidAudio's `Language` hint when it is one of
the 25; otherwise no hint (Parakeet detects within its set). A language outside the set makes the
model description say so; it is not blocked.

**No streaming for Parakeet (D2).** `DictateStreamingSession.isEligible` returns false for it:
one-shot decode of a 60 s recording is ~0.5 s, CTC boosting is more accurate on the whole file than
per chunk (FluidAudio docs, "Streaming Mode Limitations"), and it removes the merged-WAV fallback
path from the picture. Meeting live chunks still go through `SpeechService` per chunk and work
unchanged.

## Slices

Each slice is one branch, one PR, green `bash scripts/run-tests.sh`, rebuilt app. Until
2026-10-02 the Opus session types; from then Grok via `cursor-agent`.

### S1 — Engine and model behind the existing UI (M)

- Add FluidAudio `exact: 0.17.4` to both app targets (`WhisperShortcut`, `WhisperShortcut-AppStore`).
- `OfflineModelType.parakeetUltra` (+ `engine`, `displayName`, `estimatedSizeMB = 730`,
  `usesNeuralEngine = true`), `TranscriptionModel.parakeetUltra` in every switch the sweep listed
  (TranscriptionModels.swift :110, :187, :231, :249, :274, :425, :438, :546; TranscriptionProvider.swift :127).
- `ModelManager`: engine-aware `rootDirectory`/`resolveModelPath`/`isModelAvailable`/`fetch`
  (progress = Ultra 0–0.87, CTC 0.87–1.0)/`load`/`unload`/`deletionTarget`.
- `ParakeetBackend` + routing in `LocalSpeechService`, no vocabulary yet.
- `DictateStreamingSession.isEligible` false for Parakeet.
- Tests: extend `TranscriptionProviderTests` (:72 hard-coded list), `OfflineModeTests` round-trip,
  `DictateStreamingEligibilityTests`, a completeness test for the Parakeet directory.
- **Acceptance, measured, not assumed:**
  - Dictate a sentence and a 60 s monologue with Parakeet selected; `SPEED:` logs show
    post-Stop decode ≤ 0.3 s and ≤ 1 s on the M1 Pro.
  - Offline Mode on and Wi-Fi off, after a relaunch: dictation works, and `log stream` shows no
    FluidAudio download or HF request.
  - `bash scripts/rebuild-and-restart.sh --app-store` builds and codesigns. FluidAudio ships a
    prebuilt `NemoTextProcessing.xcframework` (Rust); if the App Store build or archive
    validation rejects it, switch it off via the package trait (FluidAudio's
    `Package@swift-6.2.swift`) before going further.
  - First-ever load time, measured separately from the download (ANE compile). That feeds the
    "preparing" message; the 300 s load deadline stays.

### S2 — Glossary as Parakeet vocabulary (S)

- Glossary → terms parser (unit-tested: `Terms:` prefix, newlines, duplicates, short terms).
- CTC session cache keyed by glossary text; the CTC model is loaded only when the glossary is
  non-empty.
- Engine-neutral copy: SpeechToTextSettingsTab.swift :102, `systemPromptIgnoredReason`
  (TranscriptionModels.swift :417), SmartImprovementTypes.swift :14, MenuBarController.swift :2331,
  SelfHostedTranscriptionEndpointSection.swift :163, TranscriptionProvider.swift :117-118.
- **Acceptance:** `benchmarks/local-asr` results reproduced through the app path: the osteopathy
  clip dictated via `say` → terms ≥ 22/24 with the glossary, ≤ 19/24 without.

### S3 — Make it the recommendation (S)

- `isRecommended`, `byAccuracy` (Ultra last), `mostAccurate`, `offlineTranscriptionReplacement`
  → Parakeet Ultra. Settings badge "Recommended"; Turbo's "Recommended" badge goes.
- Offline Mode card (PrivacyPermissionsTab.swift :71-78) and onboarding offline row
  (WelcomeSteps.swift :307-349): offer Parakeet Ultra. `.whisperBase` stays the "Smallest
  download" option.
- Attribution: Parakeet weights are CC-BY-4.0 (NVIDIA; Ultra retrained by Moondream),
  FluidAudio Apache-2.0 — add both wherever the app lists third-party licences, plus README.
- README `## Features` (:20, :22, :28, :36): "on-device Whisper" → on-device Parakeet or Whisper
  (own commit — shared file, bundled into the app's Chat).
- Rule and plan hygiene: `.cursor/rules/index.mdc` :30 (the "only open lever" note is now done),
  `LocalSpeechService` doc comment item 1, `plans/active/streaming-dictate.md` :457 non-goal
  pointer, queue row 18 marked superseded for Parakeet users.

## Decisions for Magnus

- **D1 — existing offline users.** Recommended: **do not switch anyone silently.** New offline
  setups and Offline Mode's automatic pick get Parakeet Ultra; someone who chose Whisper Turbo
  keeps it and sees the new "Recommended" badge and a What's New line. Alternative: migrate
  Turbo users automatically (a 730 MB download they did not ask for).
- **D2 — streaming.** Recommended: **no streaming for Parakeet** (see Design). Revisit only if
  dictations over ~3 minutes become common: one-shot is ~0.5 s per minute of audio.
- **D3 — Whisper glossary bug (queue row 18).** Recommended: fix it anyway, small and separate
  (send `promptTokens` only for single-window audio). Whisper remains for other languages.

## Falsifiers

- Post-Stop wait: the app's `SPEED:` log for offline dictations with Parakeet, median over the
  first week on the operator's Mac, must be ≤ 0.5 s. Above 1 s → the engine is not the win the
  benchmark says; investigate before the pilot.
- Accuracy: rerun `benchmarks/local-asr` against the shipped code path (S2 acceptance). Parakeet
  Ultra real-set WER more than 1.5 points above Whisper turbo → do not make it the recommendation
  (hold S3).
- Pilot: the Arztpraxis debrief (after 2026-10-15) names misheard medical terms as a top-3
  complaint → the CTC vocabulary is not enough; the next lever is a larger CTC model or keeping
  Whisper for that practice.

## Non-goals

- Parakeet v3, Redux, Apple `SpeechAnalyzer`, Cohere Transcribe, Nemotron — measured or ruled out
  above.
- A streaming Parakeet path (D2).
- Removing any Whisper model.
- iOS.
