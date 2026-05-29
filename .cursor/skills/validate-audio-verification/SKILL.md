---
name: validate-audio-verification
description: Validate end-to-end that Smart Improvement audio verification is actually working — audio is captured for dictation, attached only when the asymmetry rule passes, used by the dictation and Whisper Glossary focuses, and cleaned up afterwards. Use when the user asks "is audio verification working?", after implementing or modifying the Smart Improvement audio verification feature, or when investigating why a glossary/dictation suggestion was or was not produced.
---

# Validate Audio Verification

## Rule

Audio verification has many places where it can silently degrade to text-only behavior (master toggle off, asymmetry check fails, no matching clips, cleanup ran too early). To know it actually works, you must check **logs + on-disk state + interaction log entries** together, not any one of them in isolation.

This skill is the inspection procedure. It does **not** add logging — it assumes the `AUDIO-VERIFY:` logging contract is in place in `ContextDerivation.swift` and the dictation capture path.

---

## 1. Preconditions to confirm before validating

Before drawing any conclusions from logs:

1. The user has "Save usage data" enabled (`UserDefaultsKeys.contextLoggingEnabled` is on, or the key is unset — default is on).
2. At least one dictation has happened since the last Smart Improvement run.
3. The Smart Improvement run you are validating is recent — `bash scripts/logs.sh` covers the last ~hour by default; use `-t 24h` if needed.
4. You know which dictation backend was used (Gemini cloud vs. offline Whisper) and which Smart Improvement model is selected (from settings).

If any precondition is missing, validation results are inconclusive — say so explicitly rather than reporting "broken."

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
- `pool-trim deleted=… remaining=… capacity=…` (marker `AUDIO-VERIFY: pool-trim` in `ContextLogger.swift`) — eviction firing when the per-pool cap is hit. Not a red flag, just informational.

### Q2. Are the WAV files actually on disk?

```bash
ls -la "$HOME/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/audio-samples/" 2>/dev/null
```

Each `capture(done)` line should have a corresponding WAV file with the `ref` name. Check the pool size:

- File count should be ≤ `audioSampleMaxFiles` (default 20).
- If the count is exactly at the cap and you see `AUDIO-VERIFY: pool-trim` lines, eviction is working.

### Q3. Do interaction logs carry `audioRef` and `transcriptionModel`?

```bash
ls -t "$HOME/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/" | grep '^interactions-' | head -1
```

Read the newest interactions JSONL with the Read tool and look for the most recent line with `"mode":"transcription"`. It should include `"audioRef":"…"` and `"transcriptionModel":"…"` when capture succeeded. Older lines without these fields are expected (backward compatibility).

### Q4. Did Smart Improvement actually use the audio?

```bash
bash scripts/logs.sh -t 30m -f 'AUDIO-VERIFY' | grep -E 'run\(start\)|focus=|asymmetry|run\(end\)'
```

Expected sequence for one Smart Improvement run (verified against `ContextDerivation.swift` and `AutoPromptImprovementScheduler.swift`):

1. `run(start) samplesOnDisk=<n>` — n > 0 means there is audio to potentially use (marker `AUDIO-VERIFY: run(start)` in `AutoPromptImprovementScheduler.swift`).
2. For each of the two affected focuses (`dictation`, `glossary`), one block:
   - `focus=<focus> samplesOnDisk=<n>` — how many samples were available to that focus (marker `AUDIO-VERIFY: focus=… samplesOnDisk=` in `ContextDerivation.swift`).
   - Possibly `focus=<focus> skip reason=smart-model-unknown` (marker `AUDIO-VERIFY: focus=… skip reason=smart-model-unknown` in `ContextDerivation.swift`) — then no further per-focus output (skip path).
   - Otherwise, for each candidate clip considered: `asymmetry ref=<ref> transcriptionModel=<m> smartModel=<sm> informative=<true|false>` (marker `AUDIO-VERIFY: focus=… asymmetry ref=` in `ContextDerivation.swift`).
   - End-of-focus summary: `focus=<focus> attach selectedClips=<n> skippedAsymmetry=<n> skippedUnknownModel=<n> capPerRun=<n>` (marker `AUDIO-VERIFY: focus=… attach selectedClips=` in `ContextDerivation.swift`). `selectedClips=0` means nothing was attached for that focus.
3. `run(end) cleanup deleted=<n>` — end of run + cleanup combined (marker `AUDIO-VERIFY: run(end)` in `AutoPromptImprovementScheduler.swift`).

How to interpret common patterns:

| Pattern in logs | Meaning |
|---|---|
| `focus=… selectedClips=0 skippedAsymmetry>0` for all focuses | Transcription model ≥ Smart Improvement model on every clip. Audio correctly suppressed. |
| `asymmetry … informative=true` followed by `selectedClips>0` | Verification proceeded — happy path, audio went into the request. |
| `focus=… skip reason=smart-model-unknown` | The Smart Improvement model wasn't recognized. Check `SettingsConfiguration` and the model raw values. |
| `focus=… selectedClips=0 skippedAsymmetry=0 skippedUnknownModel=0` | No candidate clips at all — `samplesOnDisk` was 0 or no matching clip survived filtering. Could be normal (no recent dictation) or a sampling bug. |
| `focus=… selectedClips=<cap> capPerRun=<same cap>` | `audioSamplesPerRun` cap hit. Other candidates skipped — review whether the cap is too tight. |

### Q5. Was the audio cleaned up afterwards?

```bash
bash scripts/logs.sh -t 30m -f 'AUDIO-VERIFY: run(end)'
ls "$HOME/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/audio-samples/" 2>/dev/null
```

Expect one `run(end) cleanup deleted=<n>` line per Smart Improvement run (marker `AUDIO-VERIFY: run(end)` in `AutoPromptImprovementScheduler.swift`). After the run the directory should be empty (or contain only WAVs captured *after* the run started — those are for the next run and are fine).

Red flag: `run(end)` line missing, or directory not emptied — the TTL contract is broken.

---

## 3. End-to-end test recipe

When you want to actively verify (not just inspect a past run), follow this exact recipe:

1. Confirm settings: "Save usage data" on; Smart Improvement model = something strictly stronger than the transcription model (e.g. transcription = Gemini 2.5 Flash Lite, Smart Improvement = Gemini 3.1 Pro Preview). Without asymmetry the test only validates the skip path.
2. Ask the user to do **5+ dictations** including at least one with a tricky proper noun (e.g. "Kubernetes" or another technical term they actually use). Mixing in one Whisper-offline dictation is great for testing the different-family branch.
3. Ask the user to trigger Smart Improvement manually.
4. Run the five Q1–Q5 checks above in order.
5. Read the suggestion file in `…/UserContext/suggested-whisper-glossary.txt` (and the dictation focus equivalent) to confirm the *content* makes sense given what the logs say happened.

---

## 4. Reporting

When summarizing for the user:

- Lead with the bottom line: "audio verification worked end-to-end" / "audio capture works but verification skipped because …" / "broken at step X."
- Then a short table of the five questions and their answers.
- Quote exact log lines (one per finding). Do not paraphrase.
- If something is broken, identify the file and step in the audio-verification flow (`ContextDerivation.swift`, dictation capture in `SpeechService.swift`) that is implicated.

---

## When to apply

- User asks to verify, validate, or test that Smart Improvement audio verification is working.
- After any change to the Smart Improvement audio verification flow.
- When debugging why a Whisper Glossary or dictation system prompt suggestion did or did not appear, and audio verification is in play.

## When to skip

- Plain logging questions unrelated to audio verification → use `view-logs-via-bash` skill.
- Bugs in the text-only Smart Improvement pipeline (no audio involved) → use `debugging-workflow` skill.
- Before the feature is implemented — there will be no `AUDIO-VERIFY:` log lines to inspect.
