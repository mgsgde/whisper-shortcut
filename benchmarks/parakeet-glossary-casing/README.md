# Parakeet: language hint and glossary, exact spelling (2026-10-26)

Question from the practice pilot (Christoph read a 30-term medical list into Parakeet Ultra with
no glossary and auto language): does pinning the language to German, or the glossary (CTC
vocabulary boosting), fix spelling and case? Unlike `benchmarks/local-asr`, this scores terms
**case-sensitively** and keeps every transcript for reading.

Run: synthesize `clips.json` with `say -v Anna --file-format=WAVE --data-format=LEI16@16000`
(abbreviations spelled as letters, e.g. "C R P") into a folder with `terms.txt`, then
`swift build -c release && .build/release/CasingExp <folder> > results.jsonl`.
FluidAudio 0.17.7 (the app's pin), Parakeet Ultra, CTC 110m. Four arms per clip:
auto, de, auto+glossar, de+glossar.

## Result (M-series Mac, voice Anna; Flo/Sandy discarded, they speak German with English phonetics)

| arm | terms exact | terms ignoring case |
|---|---:|---:|
| auto / de (identical) | 35/59 | 36/59 |
| auto+glossar / de+glossar (identical) | 51/59 | 52/59 |

- **The language hint changes nothing.** All 36 transcripts are byte-identical between `auto` and
  `de`, with and without glossary.
- **Case is not the problem on clean speech.** Only `eGFR` (→ `EGFR`) was wrong by case alone.
- **The glossary lifts terms 35 → 51 but rewrites neighbours.** In 6 Anna clips: `HbA1c 7,2` →
  `HbA1c` (value deleted), `Bisoprolol` → `Metoprolol` (wrong drug, `weiter` deleted),
  `unter Rivaroxaban` → `Rivaroxaban`. Commas between terms also disappear.
- Spelled abbreviations in a list run together (`HBA1CCRPTSHEGFRCOPDINR`) with or without glossary.

TTS mispronounces rare words, so the no-glossary arm reads worse than a human (Christoph: 28/30).
