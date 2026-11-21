# /improve: `dictation_candidates` in `app_settings` review

Status: building (2026-11-20). Owner: Opus 5.5 session. Design source: a Fable 5.2 consult
(private eval notes). This file is the single spec for the Swift implementation **and** the
Python port the private eval uses; both must produce the same list for the same input.

## Why

`/improve` reads only the newest 15 of ~700–1400 usage-log rows a week, and even with the evidence
in view, models answer "setup looks good" because spotting a misspelling in raw rows is a side job
of a settings review. The app now scans the whole 7-day window itself, deterministically (no LLM),
and hands the model a short ranked list of words it probably gets wrong. The model judges each
candidate, supplies the spelling from world knowledge, and proposes a card or asks.

## Output shape

`app_settings` action='review' gains a key `dictation_candidates`: an array (possibly empty, only
present when usage_data is 'on') of at most **5** objects, best first:

```json
{"heard": "Cloud Code", "suggested": "Claude Code", "source": "sounds_like_known",
 "count": 5, "row_ids": ["2026-10-10T15:44:02.123Z", "..."], "also_heard": []}
```

- `heard` (string): the spelling as it appears in the log (most frequent original casing).
- `suggested` (string or null): a likely right spelling when the app has one, else null.
- `source`: one of `self_complaint`, `glossary_not_working`, `typed_correction`, `retry_diff`, `sounds_like_known`,
  `spelling_variants`, `unknown_recurring` (rank order, see below).
- `count`: number of distinct log rows whose text contains `heard` (folded, whole-token match).
- `row_ids`: `ts` of up to 5 of those rows, newest first (the model passes `heard` as `query` to
  `read_recent_interactions`; the ids let it name rows).
- `also_heard`: other spellings merged into this candidate (only `spelling_variants`; else `[]`).

## Input

- **Rows:** every `InteractionLogEntry` in the last 7 days (`InteractionLogQuery.defaultDays`).
  "Dictated text" of a row = `result` for mode `transcription`; `userInstruction` for mode `prompt`.
  "Typed text" of a row = `userInstruction` for mode `geminiChat` **only when** it is not a copy of a
  dictation: strip `<typed_by_user>`, `</typed_by_user>`, `<pasted_content>`, `</pasted_content>`
  tags, trim, and drop the row if a `transcription` row within ±180 s has a `result` whose folded,
  whitespace-collapsed text equals it or contains it. Other modes are ignored.
- **Signals:** `SignalLogEntry` rows of kind `dictationRestart` in the same window (`refTs` = the
  `ts` of the transcription that was redone).
- **Glossary:** current Whisper Glossary text.
- **History:** config-history diffs of the sections whisper glossary and dictation, any age:
  `{ts, section, added: [line], removed: [line]}` per row. The removed set is every removed line;
  the annotation time of a rejected spelling is the `ts` of the newest row whose added lines carry
  it inside `(not "…")`.
- **Product vocabulary:** the fixed list `PRODUCT_VOCABULARY` below, plus distinct `appName` values
  of the rows.

## Text helpers (both implementations must match exactly)

- `tokens(text)`: maximal runs of Unicode letters or digits (Swift: split on
  `!($0.isLetter || $0.isNumber)`; Python: `re.findall(r"[^\W_]+", text)`). Original spelling kept.
- `fold(s)`: lowercase, diacritics removed. Swift: `GlossaryDocument.fold`. Python:
  `unicodedata.normalize("NFD", s)`, drop category `Mn`, `.lower()`.
- `isNameLike(t)`: `len(t) >= 4` and (first char uppercase, or contains a digit, or has an
  uppercase char after position 0), and `fold(t)` not in `STOPWORDS`.
- `isKnownWord(t)`: correct in German or English per the system spell checker
  (`GlossaryFastLearner.isKnownWordInDictationLanguages`). Python port: batch the words through
  `scripts/spell_oracle.swift` (same NSSpellChecker calls), cache per run.
- `lev(a, b, limit)`: `GlossaryFastLearner.levenshtein` on folded strings.
- `levClose(a, b)` (the fast learner's rule): folded `a != b`, same first folded char, not
  `GlossaryFastLearner.isInflectionalVariant`, `lev <= 1` (`<= 2` when the shorter folded word has
  ≥ 8 chars).
- `close(a, b)`: `levClose(a, b)`, or the phonetic path: folded `a != b`, not an inflectional
  variant, `cologne(a) == cologne(b)` (non-empty), both folded lengths ≥ 5, length difference ≤ 2,
  and either the same first two folded chars or first chars forming one of the pairs
  {s,z} {c,k} {v,w} {f,v} {b,p} {d,t} {g,k}.
- `cologne(s)`: Kölner Phonetik on `fold(s)` with ä→a, ö→o, ü→u, ß→s first; standard rules
  (A,E,I,J,O,U,Y→0; H→-; B→1; P→1 unless before H; D,T→2 unless before C,S,Z; F,V,W→3; P before H→3;
  G,K,Q→4; C at word start before A,H,K,L,O,Q,R,U,X→4; C before A,H,K,O,Q,U,X not after S,Z→4;
  X not after C,K,Q→48; L→5; M,N→6; R→7; S,Z→8; C otherwise→8; D,T before C,S,Z→8; X after C,K,Q→8),
  collapse adjacent duplicates, then remove every 0 except a leading one. Digits are skipped.
- Glossary terms: parse the glossary with `GlossaryDocument` (Swift) / the eval's `split_terms`
  (Python): each entry's head (text before ` (not `), and its rejected spellings (inside
  `(not "…", "…")`). `glossaryHeads` = folded heads; `glossaryTokens` = folded tokens of all heads;
  `glossaryRejected` = folded rejected spellings.
- `removedTokens`: folded tokens (len ≥ 3) of every removed line, rejected spellings included.

## Sources (rank order)

Each source emits raw hits `(heard, suggested?, source, row_ts)`. Only dictated and typed text
of the rows is scanned (never `modelResponse`).

1. **self_complaint** — In dictated or typed text, split into sentences on `.`, `!`, `?`, newline
   (but not a `.` directly after `Dr`, `Fr`, `Hr`, `St`). Two patterns, case-insensitive:
   - `REPEAT_RE` = `\b([^\W\d_]{3,})\b,?\s+nicht\s+\1\b` ("Das ist Bianko, nicht Bianko": the
     transcriber wrote the same word for both sides of a correction). `heard` = group 1, kept only
     when its fold is not in `STOPWORDS` and it is not a known word or is `close` to a glossary
     head (the same filter as below).
   - else the first match of `COMPLAINT_RE` =
     `falsch (geschrieben|erkannt|transkribiert|diktiert)|schreibt man|heißt nicht|richtig geschrieben|schreibweise|buchstabier|(wrong(ly)?|incorrectly) (spelled|transcribed)|spelled (wrong|incorrectly)|misspell(ed|s)?`.
     `heard` = the name-like token nearest **before** the match start in the sentence (len ≥ 3,
     first-uppercase or digit or inner uppercase, fold not in `STOPWORDS`); if none, the nearest
     such token starting at or after the match end. Keep it only when it is not a known word or it
     is `close` to a glossary head.
   `suggested` = the glossary head `close` to `heard`, if exactly one; else null.
2. **glossary_not_working** — For each rejected spelling `X` of a glossary entry `Head (not "X")`
   whose annotation time is known: the dictated rows **after** that time containing `X` (folded,
   whole token, or whole token sequence for a multi-word `X`). At least 2 rows → `heard = X`,
   `suggested = Head`, `count` = those rows. Exempt from the glossary-rejected drop below.
3. **typed_correction** — `GlossaryFastLearner.findMatches` logic over the window: each typed token
   with first char uppercase and `len >= 4` (deduped per row) vs name-like tokens of dictated text; a
   dictated token `d` with `levClose(typed, d)` where the typed spelling occurs in fewer dictated
   rows than `d` (exact spelling counts), and not both are known words. `heard` = `d`,
   `suggested` = typed token.
4. **retry_diff** — For each `dictationRestart` signal, A = the transcription with `ts == refTs`,
   B = the next transcription row after A (≤ 120 s later). For each name-like token `a` of A whose
   fold is not among B's folded tokens: if some token `b` of B with `len >= 4` (not among A's folded
   tokens) is `close(a, b)` and `a` and `b` are not both known words, emit `heard = a`,
   `suggested = b`.
5. **sounds_like_known** — For each target term `V` (glossary heads, `PRODUCT_VOCABULARY`, app
   names; single tokens of `len >= 4` and two-token terms), scan dictated text: a single token `t`
   (or a bigram `t1 t2` for a two-token `V`, where each part is pairwise `close` or equal, and at
   least one part differs) with `close(t, V)`, appearing in **≥ 2** distinct rows. A single `t` that is
   a known word never qualifies, not even for a glossary head ("braucht" → Parakeet, "Seite" →
   Seiter); bigrams are exempt from the known-word rule ("Cloud Code" → Claude Code).
   `heard = t`, `suggested = V`.
6. **spelling_variants** — Name-like, not-known-word dictated tokens grouped by `close`: a group of
   ≥ 2 different spellings with ≥ 3 rows in total. `heard` = the most frequent spelling,
   `also_heard` = the others, `suggested` = null.
7. **unknown_recurring** — Name-like, not-known-word dictated tokens in **≥ 3** distinct rows.
   `suggested` = null.
   For 6 and 7 a folded token group is judged by its most frequent name-like spelling; if the spell
   oracle calls that one a known word, the most frequent name-like spelling with ≥ 2 rows that is
   unknown stands in (so "AutoMagic" 4 rows known, "Automagic" 2 rows unknown → unknown group, heard
   "AutoMagic" after majority casing). No such spelling → the group is a known word.

## Merge, filter, rank

- Key = `fold(heard)`. Merge hits with the same key: keep the best source (lowest rank number) and
  its `suggested`; union row ids; `count` = distinct rows containing `heard`.
- Drop a candidate when: `fold(heard)` is in `glossaryHeads` or `glossaryTokens` or
  `glossaryRejected` (already handled); or `fold(heard)` or `fold(suggested)` is in `removedTokens`
  (the user removed it on purpose); or every token of `heard` is in `STOPWORDS`; or
  `fold(heard) == fold(suggested)` and `heard` already equals the majority casing in the log.
  Also drop a `spelling_variants` or `unknown_recurring` candidate when `heard` or any of
  `also_heard` is a glossary rejected spelling (evidence after the annotation is
  `glossary_not_working`'s job; rows before it are already fixed).
  Exception: a `sounds_like_known` / `self_complaint` candidate whose `suggested` is already a
  glossary head is **kept** (the glossary entry is not working; the fix is a `(not "heard")`
  annotation).
- Drop a candidate whose `suggested` is non-null and `compact(heard) == compact(suggested)`, where
  `compact` = lowercase and remove every character that is not a letter or digit ("sabaki dance" vs
  "sabaki.dance", "Datev" vs "DATEV"). All sources, including the glossary-head exception; applied
  before the top-5 cut so the slot goes to the next candidate.
- At most one candidate per non-null `suggested` (folded): keep the higher-scoring one.
- Score: `self_complaint` 1000, `glossary_not_working` 800, `typed_correction` 500, `retry_diff` 300, `sounds_like_known` 200
  (glossary target) / 150 (other target), `spelling_variants` 100, `unknown_recurring` 0; plus
  `10 × min(count, 20)`. Sort by score desc, then count desc, then `heard` asc. Keep 5.

## Constants

`PRODUCT_VOCABULARY` (AI and developer tools the app's users talk about; do not add terms because
an eval case needs them):
Claude, Claude Code, Anthropic, OpenAI, ChatGPT, Codex, Gemini, Google, Grok, xAI, Cursor, Copilot,
GitHub, GitLab, Perplexity, Mistral, Llama, Ollama, DeepSeek, Qwen, Whisper, WhisperShortcut,
Parakeet, Xcode, Swift, Python, JavaScript, TypeScript, Slack, Notion, Figma, Supabase, Vercel,
Docker, Kubernetes, Firebase, Hugging Face, LangChain, Midjourney, ElevenLabs, WhatsApp, Telegram,
Zoom, Linear, Jira, Obsidian, Raycast, Homebrew.

`STOPWORDS` (folded): German and English function words, pronouns, sentence starters and titles
that are capitalized at sentence start: ich, du, er, sie, es, wir, ihr, mir, mich, dir, dich, uns,
euch, ihm, ihn, ihnen, das, der, die, den, dem, des, ein, eine, einen, einem, einer, und, oder,
aber, also, doch, nicht, noch, auch, nur, schon, mal, ja, nee, nein, okay, ok, gut, bitte, danke,
warum, wieso, weshalb, was, wer, wie, wo, wann, welche, welcher, welches, kannst, koennen, konnen,
kann, soll, sollen, sollte, muss, musst, wird, werden, wurde, ist, sind, war, hat, habe, haben,
hast, gibt, mach, mache, machen, dann, wenn, weil, dass, damit, hier, dort, jetzt, heute, morgen,
frau, herr, herrn, dr, prof, hallo, hey, hi, liebe, lieber, the, and, but, this, that, what, why,
how, who, when, where, which, can, could, would, should, will, please, thanks, hello, okay, yes,
also, just, then, there, here, today, tomorrow, mr, mrs, ms, dear.

## Shared test vectors (Swift XCTest and the Python self-test both pin these)

Glossary `"Terms: Läuffer, Grok Bot (not \"Grogbot\")"`, removed lines `["Seiter (not \"Seite\")"]`,
rows (newest last, all `transcription` unless noted, timestamps 1 min apart):

1. "Frau Dr. Läufer hat angerufen."
2. "Ich habe Frau Dr. Läufer geschrieben."
3. "Warum wird Läufer immer falsch geschrieben?"
4. "Wir nutzen Cloud Code für das Projekt."
5. "Cloud Code ist gut."
6. "Grogbot startet nicht."
7. "Die Seite lädt nicht."
8. "Die Seite ist neu."
9. "Termin mit Zorvex am Montag." 10. "Zorvex hat abgesagt." 11. "Zorvex kommt später."

Spell checker stub for the vectors: `isKnownWord(t) = fold(t) not in {"zorvex", "grogbot", "lauffer", "bianko"}`.
The removed line is given as one history row (section whisper glossary, removed only, ts before
all rows).
No signals, no typed text, no app names.

Expected (order matters): `Läufer` (self_complaint, suggested `Läuffer`, count 3), `Cloud Code`
(sounds_like_known, suggested `Claude Code`, count 2), `Zorvex` (unknown_recurring, count 3).
Not present: `Grogbot` (glossary rejected spelling), `Seite` (removed set).

**Vector B** (glossary not working). Glossary `Grok Bot (not "Grogbot")`; history: one whisper
glossary row at T0 adding `Grok Bot (not "Grogbot")`; rows after T0: "Grogbot startet nicht.",
"Der Grogbot hängt." Expected: exactly `Grogbot` (glossary_not_working, suggested `Grok Bot`,
count 2). With the history row's ts moved after both rows: empty list.

**Vector C** (repeated word). Empty glossary, no history; one row "Das ist Bianko, nicht Bianko,
merk dir das." Expected: exactly `Bianko` (self_complaint, suggested null, count 1).

## Spec decisions taken during the build (both ports follow them)
- The known-word rule (sounds_like_known) applies to single tokens only, never to bigrams, and has no glossary-head exemption (v5).
- The "kept" exception (suggested already a glossary head) only overrides the casing drop; a heard
  word that is a glossary head, glossary token or in the removed set is always dropped. A rejected
  spelling is dropped too, except from `glossary_not_working`.
- `removedTokens` / glossary checks compare `fold(heard)` as a whole string, so a multi-word heard
  never matches a single token.
- Self-complaint "after" tokens start at or after the match end.
- typed_correction counts use exact spellings (as `findMatches`); typed tokens already in the
  glossary are skipped.
- `count` / `row_ids` come from all scanned rows (dictated and typed) containing the folded token
  or bigram, except `glossary_not_working` (rows after the annotation time).
- A sentence where `REPEAT_RE` matches is not scanned with `COMPLAINT_RE` (the "else").
- The removed-set drop still applies to `glossary_not_working` (only the glossary-rejected drop is exempt).
- `glossary_not_working` rows are those with `ts` strictly after the annotation `ts`; when a
  `self_complaint` hit wins the merge for the same spelling, `count`/`row_ids` use all rows.
- The phonetic first-char pairs are unordered.

## History
- v1 (2026-11-20): first offline recall over the private eval: 3/8 at rank ≤ 5. Noise from broad
  complaint patterns ("merk dir", "nicht X, sondern"), loose phonetic matches on short known words
  and retry diffs between ordinary words; a rejected spelling still dictated after it was annotated
  was dropped instead of surfaced.
- v2 (2026-11-20): narrower complaint patterns plus REPEAT_RE, stricter phonetic path, `levClose`
  for typed corrections, retry diff needs one unknown word, sounds_like_known no longer requires the
  target to be rarer, new source `glossary_not_working`. Offline recall 6/8.
- v3 (2026-11-20): REPEAT_RE hits get the stopword/known-word filter ("diese, nicht diese" was
  rank 1); variant groups containing an annotated wrong spelling are dropped (a negative case
  failed on it); one candidate per suggested term.
- v4 (2026-11-21): drop candidates whose suggestion differs only in case, spacing or punctuation
  (`compact` equality, all sources). Live path: spell-check cap 1500 words, words past the cap count
  as known, compute runs off the main actor.
- v5 (2026-11-21): sounds_like_known drops a known-word single-token `heard` also when the target is a
  glossary head (ordinary words like "braucht", "Seite", "Platz", "Sales" were top-5 noise). The
  removed-set drop on `suggested` is pinned by a test in both ports.
  Unknown-ness fallback for 6/7: a group whose most frequent spelling is a known word is still unknown
  when a name-like spelling with ≥ 2 rows is (regression: case `automagic`, "AutoMagic" is known to the
  checker, "Automagic" is not).
