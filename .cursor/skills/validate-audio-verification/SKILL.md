---
name: validate-audio-verification
description: Validate end-to-end that Smart Improvement audio verification is actually working — audio is captured for dictation, selected content-aware to verify recurring candidate terms, attached only when the asymmetry rule passes, used by the dictation and Whisper Glossary focuses, and retained across runs (pruned by age). Use when the user asks "is audio verification working?", after implementing or modifying the Smart Improvement audio verification feature, or when investigating why a glossary/dictation suggestion was or was not produced.
---

# Validate Audio Verification

## Rule

Audio verification has many places where it can silently degrade to text-only behavior (master toggle off, asymmetry check fails, no clip on disk for the candidate term, smart model unknown). To know it actually works, you must check **logs + on-disk state + interaction log entries** together, not any one of them in isolation.

This skill is the inspection procedure. It does **not** add logging — it assumes the `AUDIO-VERIFY:` logging contract is in place in `ContextDerivation.swift` and the dictation capture path.

**Audio retention model (current):** audio is **retained across Smart Improvement runs**, not wiped after each one. It is pruned by age at the start of each run (`audioSampleRetentionDays`, default 30 — matching the text-analysis window), and bounded by a large safety cap (`audioSampleMaxFiles`, default 500). Selection is **content-aware**: per focus, one representative clip is chosen for each recurring candidate term mined from the dictation transcripts (newest clip containing it), then the newest clips top up to the per-run cap. This is what lets a term mis-heard across the whole history (e.g. "Claude" → "Cloud") get its audio in front of the verifier.

---

## 1. Preconditions to confirm before validating

Before drawing any conclusions from logs:

1. The user has "Save usage data" enabled (`UserDefaultsKeys.contextLoggingEnabled` is on, or the key is unset — default is on).
2. At least one dictation has happened, and ideally the candidate term you care about recurs in ≥2 distinct dictations whose **WAV files are still on disk** (within the retention window).
3. The Smart Improvement run you are validating is recent — `bash scripts/logs.sh` covers the last ~hour by default; use `-t 24h` if needed.
4. You know which dictation backend was used (Gemini cloud vs. offline Whisper) and which Smart Improvement model is selected (from settings).

If any precondition is missing, validation results are inconclusive — say so explicitly rather than reporting "broken." In particular: a term whose audio was captured **before** the retention model shipped (or older than `audioSampleRetentionDays`) is gone from disk; content-aware selection cannot retroactively verify it even though the text still logs it.

---

## 2. The five validation questions

For each question, the answer comes from one specific log filter or file check. Walk through them in order.

### Q1. Was audio captured for recent dictations?

```bash
bash scripts/logs.sh -t 30m -f 'AUDIO-VERIFY: capture'
```

Expect one line per dictation. Acceptable outcomes:
- `capture(done) ref=… backend=… transcriptionModel=… sizeBytes=…` — captured (marker `AUDIO-VERIFY: capture(done)` in `ContextLogger.swift`).
- `capture(skip) reason=logging-disabled` — master toggle off (precondition failed; not a bug; marker `AUDIO-VERIFY: capture(skip)` in `ContextLogger.swift`).

Red flags:
- `capture(error) reason=…` lines (marker `AUDIO-VERIFY: capture(error)` in `ContextLogger.swift`) — investigate the reason.
- No `AUDIO-VERIFY: capture(...)` lines at all despite a dictation: the capture hook is not wired or is upstream of the dictation completion.
- `pool-trim deleted=… remaining=… capacity=…` (marker `AUDIO-VERIFY: pool-trim` in `ContextLogger.swift`) — eviction firing only when the large safety cap (default 500) is hit. Rare in normal use; informational, not a red flag.

### Q2. Are the WAV files actually on disk?

```bash
ls -la "$HOME/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/audio-samples/" 2>/dev/null
```

- WAVs **accumulate across runs** now — expect more than one run's worth. Each `capture(done)` line should have a corresponding WAV with the `ref` name until it ages out.
- File count should be ≤ `audioSampleMaxFiles` (safety cap, default 500).
- The oldest file should be no older than `audioSampleRetentionDays` (default 30 days) after a run — age pruning happens at run start (marker `AUDIO-VERIFY: prune-age` in `ContextLogger.swift`).

### Q3. Do interaction logs carry `audioRef` and `transcriptionModel`?

```bash
ls -t "$HOME/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/" | grep '^interactions-' | head -1
```

Read the newest interactions JSONL with the Read tool and look for the most recent line with `"mode":"transcription"`. It should include `"audioRef":"…"` and `"transcriptionModel":"…"` when capture succeeded. The `audioRef` → `result` (transcribed text) mapping in these logs is exactly what drives candidate-term extraction, so missing `audioRef`/`result` fields blind the content-aware selection. Older lines without these fields are expected (backward compatibility).

### Q4. Did Smart Improvement actually use the audio?

```bash
bash scripts/logs.sh -t 30m -f 'AUDIO-VERIFY' | grep -E 'run\(start\)|prune-age|focus=|asymmetry|candidateTerms|run\(end\)'
```

Expected sequence for one Smart Improvement run (verified against `ContextDerivation.swift` and `AutoPromptImprovementScheduler.swift`):

1. Optionally `prune-age deleted=<n> remaining=<m> olderThanDays=30` — age pruning at run start (marker `AUDIO-VERIFY: prune-age` in `ContextLogger.swift`). Absent when nothing was old enough to prune.
2. `run(start) samplesOnDisk=<n>` — n > 0 means there is audio to potentially use (marker `AUDIO-VERIFY: run(start)` in `AutoPromptImprovementScheduler.swift`).
3. For each of the two affected focuses (`dictation`, `whisperGlossary`), one block:
   - `focus=<focus> samplesOnDisk=<n>` — how many samples were available to that focus (marker `AUDIO-VERIFY: focus=… samplesOnDisk=` in `ContextDerivation.swift`).
   - Possibly `focus=<focus> skip reason=smart-model-unknown` (marker in `ContextDerivation.swift`) — then no further per-focus output (skip path).
   - `focus=<focus> candidateTerms=<n> top=[term1, term2, …]` — the recurring candidate terms mined from the transcripts that drive selection (marker `AUDIO-VERIFY: focus=… candidateTerms=` in `ContextDerivation.swift`). `candidateTerms=0` means no recurring distinctive vocabulary was found; selection falls back to newest clips.
   - For each clip considered/attached: `asymmetry ref=<ref> transcriptionModel=<m> smartModel=<sm> informative=<true|false>`; attached clips also carry `term=<candidate|—>` showing which candidate term the clip was selected to verify (`—` = recency top-up) (marker `AUDIO-VERIFY: focus=… asymmetry ref=` in `ContextDerivation.swift`).
   - End-of-focus summary: `focus=<focus> attach selectedClips=<n> skippedAsymmetry=<n> skippedUnknownModel=<n> capPerRun=<n> candidateTerms=<n>` (marker `AUDIO-VERIFY: focus=… attach selectedClips=` in `ContextDerivation.swift`). `selectedClips=0` means nothing was attached for that focus.
4. `run(end) retainedSamples=<n>` — end of run; audio is **kept** for future runs (marker `AUDIO-VERIFY: run(end)` in `AutoPromptImprovementScheduler.swift`).

How to interpret common patterns:

| Pattern in logs | Meaning |
|---|---|
| `focus=… selectedClips=0 skippedAsymmetry>0` for all focuses | Transcription model ≥ Smart Improvement model on every clip. Audio correctly suppressed. |
| `asymmetry … informative=true term=<X>` followed by `selectedClips>0` | Content-aware verification proceeded — happy path, audio for candidate term `<X>` went into the request. |
| `focus=… skip reason=smart-model-unknown` | The Smart Improvement model wasn't recognized. Check `SettingsConfiguration` and the model raw values. |
| `focus=… candidateTerms=0` then `selectedClips>0 term=—` only | No recurring distinctive vocabulary; selection fell back to newest clips. Normal early on or for very generic dictations. |
| `focus=… selectedClips=0 skippedAsymmetry=0 skippedUnknownModel=0` | No candidate clips at all — `samplesOnDisk` was 0 or no on-disk clip matched any candidate term and no eligible newest clip existed. Could be normal (no recent dictation) or a selection bug. |
| `focus=… selectedClips=<cap> capPerRun=<same cap>` | `audioSamplesPerRun` cap hit (default 12) — more candidate terms than slots. The top terms (by distinct-transcript frequency) were covered; review whether the cap is too tight if an important term was crowded out. |

### Q5. Is the audio retained correctly afterwards (not wiped, but age-bounded)?

```bash
bash scripts/logs.sh -t 30m -f 'AUDIO-VERIFY: run(end)'
ls "$HOME/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/audio-samples/" 2>/dev/null
```

Expect one `run(end) retainedSamples=<n>` line per Smart Improvement run (marker `AUDIO-VERIFY: run(end)` in `AutoPromptImprovementScheduler.swift`). After the run the directory should **still contain** the WAVs (audio is retained for future runs) — an **empty** directory after a run is now the red flag (it would mean something is wiping the pool).

Red flags:
- `run(end)` line missing.
- Directory emptied after a run (audio must persist now).
- A clip on disk **older** than `audioSampleRetentionDays` surviving past a run start without a `prune-age` line — the age-prune contract is broken.

---

## 3. End-to-end test recipe

When you want to actively verify (not just inspect a past run), follow this exact recipe:

1. Confirm settings: "Save usage data" on; Smart Improvement model = something strictly stronger than the transcription model (e.g. transcription = Gemini 2.5 Flash Lite, Smart Improvement = Gemini 3.1 Pro Preview). Without asymmetry the test only validates the skip path.
2. Ask the user to do **5+ dictations** that **repeat a tricky proper noun across at least 2 of them** (e.g. "Kubernetes", a product/tool name they actually use, or a term their STT mis-hears). Recurrence is what makes it a candidate term; a one-off won't be selected. Mixing in one Whisper-offline dictation is great for testing the different-family branch.
3. Ask the user to trigger Smart Improvement manually.
4. Run the five Q1–Q5 checks above in order. In Q4, confirm the term you seeded appears in `candidateTerms=… top=[…]` and that a clip was attached with `term=<that term>`.
5. Read the suggestion file in `…/UserContext/suggested-whisper-glossary.txt` (and the dictation focus equivalent) to confirm the *content* makes sense given what the logs say happened.

---

## 4. Reporting

When summarizing for the user:

- Lead with the bottom line: "audio verification worked end-to-end" / "audio capture works but verification skipped because …" / "broken at step X."
- Then a short table of the five questions and their answers.
- Quote exact log lines (one per finding). Do not paraphrase.
- If something is broken, identify the file and step in the audio-verification flow (`ContextDerivation.swift`, dictation capture in `SpeechService.swift`, retention/selection in `ContextLogger.swift`) that is implicated.

---

## When to apply

- User asks to verify, validate, or test that Smart Improvement audio verification is working.
- After any change to the Smart Improvement audio verification flow.
- When debugging why a Whisper Glossary or dictation system prompt suggestion did or did not appear, and audio verification is in play.

## When to skip

- Plain logging questions unrelated to audio verification → use `view-logs-via-bash` skill.
- Bugs in the text-only Smart Improvement pipeline (no audio involved) → use `debugging-workflow` skill.
- Before the feature is implemented — there will be no `AUDIO-VERIFY:` log lines to inspect.
