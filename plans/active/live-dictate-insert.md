# Live dictation into the cursor (Dragon-style), offline Parakeet

Status: S1–S4 written 2026-11-02 on branch `feat/live-dictate-insert` in a Linux cloud session —
**not yet compiled or run on a Mac.** v1 decisions taken there: paste (not type); a period at the end
of a piece is held back and dropped when the next piece starts lowercase (`LiveChunkJoiner`); the
shortcut row lives in Settings → General like Add to Glossary. Comes from the pilot user (long medical reports, offline
Parakeet, previously Dragon): she expects the text **where the cursor is, while she speaks** — as
Dragon does — not after Stop. Magnus had the same intuition. This changes the direction of
`live-dictate-preview.md` (PR #318, a read-only panel; text still pasted after Stop): park that PR
until this mode has been tried by the pilot, then decide whether the panel still earns a place.

## What Dragon does, and what we copy

Dragon Medical inserts text at the cursor **after each short pause** (an utterance), not word by
word, and does not rewrite text it already inserted; corrections are the user's (by voice or by
hand). Medical best practice for this "front-end" recognition is that the dictating person reads
the text and corrects it before signing — that review, not a perfect recogniser, is the safety
mechanism.

We copy exactly that shape: **append-only, cut at speech pauses, never rewrite.** Rewriting text in
a foreign app (undo stacks, moved cursor, apps that reject synthetic edits) is the fragile part,
and an append-only design never needs it.

## What the user sees

- A new shortcut **Dictate Live** (unassigned by default; Settings → General, menu bar item). The
  normal Dictate shortcut does not change.
- Press it, speak. After each pause of ~0.6 s the words since the last pause appear at the cursor,
  typically within ~1 s of the pause. The pill shows "Live" while recording.
- Press again (or ✓) to stop: the last piece is inserted. ✕ stops too, but **text already inserted
  stays** (it is in the other app; the pill's tooltip and README say so).
- Only with offline Parakeet Ultra (downloaded) on Apple Silicon, and only where auto-paste works:
  direct/GitHub build with the Accessibility permission. The App Store build does not offer it
  (no synthetic paste there, Guideline 2.4.5). Otherwise the shortcut row is disabled with the
  reason.

## Design

1. **Pieces at pauses.** `ChunkedDictateRecorder` already rotates at silence boundaries; today only
   after ≥ 10 s and 1 s of silence (`AppConstants.dictateChunkMinDuration` /
   `dictateChunkSilenceDuration`, tuned for streaming Dictate). Make the two values per-session
   parameters with today's values as default (normal Dictate unchanged) and start live sessions with
   ~1.5 s minimum and ~0.6 s silence. Silence is sampled every 0.2 s, so 0.6 s = 3 samples. Measure
   on the pilot's recordings before settling the numbers.
2. **Decode each piece once.** Each rotated chunk goes through the normal offline path
   (`SpeechService.transcribe` → `LocalSpeechService` → `ParakeetBackend.transcribe`, with Glossary
   boosting and `SpokenPunctuation`), strictly in order (one serial queue; Parakeet decodes a
   sentence in ~0.1 s). Silent chunks are skipped (`isSilent`). No sliding window, no second engine.
3. **Insert, append-only.** A pure `LiveChunkJoiner` decides the text to insert for each piece:
   leading space unless the previous piece ended a line, and how to treat sentence punctuation at a
   cut that was only a breath mid-sentence (open question below). Insertion reuses the existing
   paste-at-cursor path (`ClipboardManager` + `simulatePaste`), with the user's clipboard restored
   once at the end of the session, not per piece.
4. **Target guard (patient safety).** The target app is recorded at start (`pasteTargetAtRecordStart`
   already exists). If another app is frontmost when a piece is ready, the piece is **held**, not
   inserted elsewhere — a wrong-window insert could land in another patient's record. Held pieces
   go in when the original app is frontmost again; at Stop, anything still held is copied to the
   clipboard with a popup saying so.
5. **Result and history.** The session's transcript is the joined inserted text; it goes to
   "Copy Last Transcription", the history and the usage log like a normal dictation. The full
   recording is kept as today (Retry, cancelled-recording recovery).
6. **Measure the accuracy question instead of guessing.** After Stop, decode the whole recording
   once more in the background (single-shot, ~0.5 s per minute, offline) **only to log** the word
   edit distance between the inserted text and the single-shot text — counts only, never words.
   That answers "how much do pieces cost against the whole file" on real dictations.

## As built after the independent review (2026-11-02)

- A live session exists only for a live recording: created before the recorder starts, ended on
  every discard/cancel/failure path, on a cancelled or empty start, and at every normal Dictate
  start; rotated chunks reach it only while the recording is flagged live.
- The paste target is checked again right before ⌘V (a ⌘Tab in between must not redirect a piece);
  no recorded target or a secure (password) field → the piece waits.
- Pieces go through the clipboard marked transient/concealed and current-host-only (no clipboard
  history apps, no Universal Clipboard), 0.4 s apart. With "Restore clipboard" on, the clipboard
  from before the recording comes back at the end and on every cancel.
- A failed piece never leaves a silent gap: the whole file is decoded onto the clipboard with a
  notice; if that fails too, the notice says so and the recording is kept.
- The drift measurement waits until the app has been idle for 10 s and is skipped otherwise.
- The auto-paste setting is not required: pressing Dictate Live is the request to type at the cursor.

Known gaps, deliberately not in v1:
- Switching to another window **inside the same app** (another patient in the same EHR) is not
  detected; the guard is per app. Next step: record the focused AX window at start and hold if it
  changes.
- A recording error at Stop (merge failed) drops held text and the tail piece.
- Live dictations add no audio sample for Smart Improvement and no Writing Style sample.
- "Transcribe Cancelled Recording" after a cancelled live dictation pastes the whole text, on top of
  the pieces already inserted.
- A ⌘C made mid-dictation is overwritten by the next piece.

## Fn option (branch `feat/live-dictate-fn`, 2026-11-02: both schemes build, unit tests pass, not yet tried by hand)

The pilot user only uses Fn (press to start, press again to stop), so Settings → General →
Keyboard Shortcuts has a second row under the Fn toggle: **Fn key starts** = Dictate (default,
unchanged) | Dictate Live. With Live chosen, Fn starts a Live session through the same entry as the
Dictate Live shortcut (`toggleLiveDictation`); the second Fn press stops it like the shortcut or ✓,
a press while processing cancels as before, and Fn used as a modifier right after the start discards
the recording (text already inserted stays). If Live cannot start right now (model not downloaded,
meeting running, Intel Mac) Fn shows the same notice as the shortcut and starts nothing: no silent
fallback to normal Dictate. Fn only ends the kind of recording it started (`fnStartedLive`), so a
recording begun by the other shortcut is never stopped by an Fn session of the other kind. The row's
Live choice is refused in Settings while Live is unavailable (reason shown); the meeting condition is
only checked at the press. Not in the App Store build. Pure decision: `LiveDictation.fnStartDecision`.

## Open questions (measure or decide)

- **Punctuation at mid-sentence pauses.** Parakeet punctuates each piece on its own and may end a
  breath pause with "." and start the next piece capitalised. Candidate: hold back a piece's final
  sentence mark and emit it with the next piece (". " if the next piece starts a sentence, " "
  otherwise), flushing it at Stop. Decide from the pilot's recordings; German capitalises nouns, so
  "next piece starts with a capital" is weak evidence.
- **Paste vs. type.** Pasting is the path proven in her practice software; typing via
  `CGEvent.keyboardSetUnicodeString` would leave the clipboard alone but behaves differently in
  browsers and remote desktops. v1: paste. Revisit if the clipboard churn bothers her.
- **Voice commands across a cut** ("neuer" | pause | "Absatz") — rare; check in the logs.
- **PR #318 (read-only panel):** keep as an option for users who want the whole-file result, or
  close. Decide after the pilot has used this mode.

## Slices

- **S1 (pure, testable on Linux):** `LiveChunkJoiner` (spacing, line ends, punctuation policy),
  the target-guard decision (insert / hold / flush to clipboard), eligibility
  (Parakeet + downloaded + Apple Silicon + auto-paste available + not App Store). Unit tests.
- **S2:** per-session rotation parameters in `ChunkedDictateRecorder` (defaults unchanged, a test that
  normal Dictate keeps 10 s / 1 s).
- **S3:** `LiveDictateSession` (serial decode, joiner, target guard, paste, clipboard restore once),
  wiring in `MenuBarController` (start, stop, ✕, failure), `LIVE-DICTATE:` log lines per piece
  (chunk seconds, decode ms, chars, held/inserted) and the post-Stop accuracy line.
- **S4 (UI, by the Opus session):** shortcut + menu item, disabled reasons, pill label, README
  Features line, strings (English + German).

## Falsifiers (on the pilot's Mac, release build)

- Pause → text at cursor: median ≤ 1.0 s, p90 ≤ 1.5 s over a 3-minute dictation.
- Word edit distance inserted vs. single-shot: median ≤ 3 % of words. Above that, pieces cost real
  accuracy and the punctuation / minimum-length choices get revisited.
- Zero inserts into an app other than the one at start (log check).
- The pilot uses Dictate Live for her reports in the week after release instead of Dictate (her
  own words or usage counts; `TOO EARLY` until she has the release).

## Non-goals

Rewriting already inserted text, live text for cloud models (per-piece network latency), Dictate
Prompt, meetings, voice-command navigation between fields ("nächstes Feld").
