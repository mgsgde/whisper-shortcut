# Dictation benchmark

Does a new speech model, or a change to the post-processing after it, break dictation, and is it
better? This benchmark answers that for offline dictation in German, run through the same path
Dictate Live uses:

`LocalSpeechService.transcribe(…, spokenMarksOnly:)` (with the Glossary handed to the engine the way
`SpeechService` does it) → `LiveDictation.finishPiece` → `LiveChunkJoiner` for back-to-back dictations.

It scores both punctuation modes: **"Only when spoken"** (`PunctuationMode.spokenOnly`), where only
a spoken "Komma", "Punkt", "Doppelpunkt", "Schrägstrich", "drei Pünktchen" … may become a mark, and
**Automatic**, where the model's own punctuation stays.

## Run it

```bash
cd whisper-shortcut
bash scripts/dictation-benchmark.sh                          # Parakeet Ultra, say voices + real voice
bash scripts/dictation-benchmark.sh --model whisper-large-turbo
bash scripts/dictation-benchmark.sh --update-baseline        # accept the current scores
```

Flags: `--model <OfflineModelType raw value>`, `--voices "Anna,Eddy (German (Germany))"`,
`--real-audio DIR`, `--no-say`, `--update-baseline`. It prints the failing sentences, then one table:
one row per score, one column per audio tier and mode, the change against the baseline in
parentheses, `!` on a regression. Exit status 1 means a score fell below its baseline (or the run did
not happen at all — "benchmark did not run" is never a pass). Full log:
`build/dictation-benchmark/xcodebuild.log`, the parsed run in `last-run.tsv` / `last-run.json`.

The script kills and restarts nothing; a running Dev build or the installed app can stay open.

## What is in it

- **`corpus.json`** — about 40 invented practice-style sentences (no patient data, ever): spoken
  marks, sentences with no spoken mark where nothing may be added, "?"/"!" said versus guessed,
  numbers (digits or words both accepted, Parakeet writes either), Glossary terms and the words the
  Glossary must not rewrite, fillers ("äh", "hm"), "Punkte"/"Kommas" that stay words, and two
  dictations back to back. Its `about` field is the schema.
- **Audio tiers.** `say-<voice>`: macOS `say` voices, cheap and always available, but they pause
  unlike people — spoken commas that a person keeps get lost, and the other way round. `real`: one
  human recording per dictation, `<id>.wav` or `<id>-1.wav`, `<id>-2.wav`. **The recordings never
  go into this public repo.** The script reads them from `--real-audio`, else
  `$WHISPERSHORTCUT_BENCH_AUDIO_DIR`, else `../business/pilot-praxis/benchmark-audio/magnus` in the
  private parent repo (which also holds `record.py`, the script that walks a speaker through the
  corpus). Without any of these the real tier is skipped, and the script says so.
- **`baseline.json`** — the scores to hold, per model and tier. Scores only, no audio, no transcripts.

## The scores

Per tier and mode, each a share between 0 and 1:

| score | what it measures |
|---|---|
| `exact` | sentences that came out exactly as expected (or as an accepted alternative) |
| `spokenMarksKept` | expected marks that are there, in order (LCS of the mark sequences) |
| `noGuessedMarks` | sentences without a single mark too many — in "Only when spoken" the guesses the model must not keep |
| `glossary` | Glossary sentences where every expected term is there and no other Glossary term crept in ("erreicht" must not become "Merkzeichen", "Komma" never "Kizomba") |
| `wordAccuracy` | 1 − word error rate, marks and case ignored |
| `tag.<tag>` | `exact` within one group of the corpus (`spokenMarks`, `noMarks`, `guess`, `numbers`, `glossary`, `fillers`, `wordsStay`, `joined`) |

## The gate

The test fails only when a score drops below its baseline. It does not gate a tier whose input
changed, and says why in a `BENCH-NOTE` line: a changed `corpus.json`, a different set of real
recordings, a different macOS (the `say` voices change with it), or missing recordings. Then run
with `--update-baseline` once, and commit `baseline.json` in the same commit as the change that
moved it.

Raising the baseline is fair game whenever a change makes things better. **Lowering it is a human
decision**: a model or post-processing change that drops a score needs Magnus's word, in its own
commit, saying which score and why (`AGENTS.md`: no agent weakens the gate it is judged by).

## Testing a new model ("neues Modell testen")

1. Add the model (`OfflineModelType`, download, `LocalSpeechService` engine) as usual.
2. `bash scripts/dictation-benchmark.sh --model <new raw value>` — its first run is all `NEW`.
3. Compare with the current model's columns in `baseline.json` (or run both). Better means: no
   score lower than today's default model's on the `real` tier, and the `say` tiers no worse either
   — synthetic voices catch breakage, the real voice decides.
4. Post-processing changes (`SpokenPunctuation`, `ParakeetPunctuationTiming`,
   `ParakeetVocabularyGuard`, `LiveChunkJoiner`): run it before you open the PR; a regression fails it.
5. When a new model becomes the default, `--update-baseline` for it and keep the old model's entry
   as the comparison.

Why a config file and not environment variables: the test host is the sandboxed App Store build,
and neither a shell export nor a `TEST_RUNNER_` variable reaches it (see
`OfflineWhisperBenchmarkTests`). The script writes `build/dictation-benchmark/config.json`, the test
runs only while that file exists and is fresh, and the script removes it afterwards — so
`run-tests.sh` never runs the benchmark.
