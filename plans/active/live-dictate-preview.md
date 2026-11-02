# Live text while dictating (offline, Parakeet), opt-in

Status: planned 2026-11-02. Supersedes queue row 65's "do not build yet": build it as an
**opt-in setting, off by default**. The default dictation flow does not change.
S1–S4 written 2026-11-02 on branch `feat/live-dictate-preview` in a Linux cloud session —
**not yet compiled or run on a Mac**; the Verification list below is still open. Two independent
reviews (correctness against FluidAudio 0.17.7, and design) changed the build; see "As built".

## Why

A user who dictates long texts (medical reports) wants to read along while speaking. Today the
text appears only after Stop. The maintainer does not want this for himself, so it is a setting.

## What the user sees

- Settings → Speech to Text: toggle **"Show live text while dictating"** (off by default). Only
  enabled when the Dictate model is Parakeet (offline) and its files are downloaded. Otherwise it
  is disabled with a caption that says why ("Available with the offline Parakeet model").
- While recording with the toggle on, a small floating panel appears at the bottom center of the
  screen showing the text so far. It is non-activating (never steals focus from the target app),
  stays above other windows, and has no buttons. Confirmed words are shown in normal color,
  the still-changing tail is dimmed. The panel auto-scrolls and shows at most ~6 lines.
- On Stop the panel closes and the final text is pasted exactly as today.

**v1 does not type into the target app live.** Inserting text and later rewriting it in a
foreign app is fragile (undo stacks, cursor moves, apps that reject synthetic edits). Revisit
only if users ask for it after using the preview.

## Design

1. **The final transcript does not change.** Stop still runs today's single-shot Parakeet decode
   of the merged WAV, with Glossary boosting and every post-processing step. The live text is a
   preview only. If anything in the live path fails, the panel hides itself and dictation
   finishes normally. This keeps `parakeet-offline.md` D2 intact for the result.
2. **Engine:** FluidAudio's `SlidingWindowAsrManager` (TDT, overlapping windows). It loads from
   the same `AsrModels` the app already has (`loadModels(_ models: AsrModels)`), so there is **no
   extra download**. It supports `configureVocabularyBoosting` (pass the Glossary) and
   `applying(language:)` (pass the Dictate language). Do not use the EOU/Nemotron streaming
   variants: they are separate, mostly English models and would need a second download.
   All FluidAudio usage stays inside `ParakeetBackend.swift` (its doc comment says it is the only
   file that imports FluidAudio). Expose a small app-side type there, for example
   `ParakeetLivePreview` with `start(language:glossary:)`, `append(_ buffer:)`,
   `onText: (committed: String, tentative: String) -> Void`, and `stop()`.
3. **Audio:** `ChunkedDictateRecorder` records with `AVAudioRecorder` to files and has no buffers.
   When the toggle is on, add a parallel `AVAudioEngine` input tap that feeds PCM buffers to the
   preview. Recording to files stays exactly as it is. Start the tap after the recorder started.
   Stop it before finalize. On any tap error, log and drop the preview only.
4. **Wiring:** start and stop next to where `DictateStreamingSession.makeIfEligible` is used in
   `MenuBarController`. Cancel paths (Esc, discard) must also close the panel.
5. **Panel:** new `LiveDictatePanel` (an `NSPanel`, `.nonactivatingPanel`, `.floating`, joins all
   spaces, ignores mouse events) hosting a small SwiftUI view. Follow the app's existing overlay
   styling, if there is a recording overlay or HUD reuse its look.
6. **Cost guard:** the preview decodes repeatedly. Measure CPU and ANE load with a 3 minute
   dictation on the release build. If decode time per window exceeds ~30 % of the window hop,
   increase the hop. Log one `LIVE-PREVIEW:` summary line per session (windows, mean decode ms,
   errors) through `DebugLogger`.

## As built (deviations from the design above, 2026-11-02)

- **No app-side text merger.** S1 first had `LiveTranscriptMerger`, rebuilding committed/tentative
  text from window updates. FluidAudio already keeps `confirmedTranscript` / `volatileTranscript`
  with seams repaired from the real token positions (#897) and Glossary replacements applied; a
  text-only merge deleted genuine repeats ("die die"), short words before a longer one ("an" →
  "anamnestisch") and missed shortened re-decodes. The panel now reads the engine's two strings in
  one actor turn after every update. S1's pure, tested logic is the display tail
  (`LiveDictatePreviewText.displayTail`) and the preview-vs-final drift count.
- **"Confirmed" is not "final".** In FluidAudio it means "decoded with confidence ≥ 0.85 once 10 s of
  audio exist", and seam repair can still edit it. The panel dims the newest part and says the final
  text follows after Stop; it promises nothing more.
- **Windows:** 9 s left + 4 s hop + 2 s right (`ParakeetLivePreview.windowConfig`), not FluidAudio's
  2 + 11 + 2: text at 6 s, 10 s, 14 s, … Cost is the full 15 s window every 4 s (3.75× the audio).
- **Audio:** the tap starts with the recording and queues until the engine is built (the opening
  words were lost otherwise), converts to 16 kHz mono (first input channel) with one long-lived
  converter, and rebuilds itself once on a device change (Bluetooth headsets switch profile when
  their mic opens); a second change ends the preview.
- **Model load:** the preview waits on the shared Parakeet load without being able to cancel it
  (`LocalSpeechService.parakeetBackendForLivePreview`).
- **Panel:** a child window of the recording pill, shown with the first words; VoiceOver reads the
  text as the element's value, no live announcements.
- **Apple Silicon only:** the setting is unavailable on Intel Macs.
- **Logs:** `LIVE-PREVIEW: summary` (windows, mean/max lag past the window's ready time, errors, tap
  restarts) and `LIVE-PREVIEW: drift` (preview vs pasted word counts and word edit distance, never
  the words). FluidAudio's updates carry no decode time, so "lag" stands in for "decode ms".

Open, needs the Mac (falsifiers):
- Post-Stop `SPEED:` median with the toggle on vs off: D2's ≤ 0.5 s must still hold with it on. If
  not, make the final decode wait for the preview's cancellation.
- `meanLagMs` on a 3-minute dictation, release build: above ~30 % of the hop (1.2 s) → raise the hop.
- Drift on real German dictations, and 9/4/2 vs 11/2/2 vs 2/11/2 on the same WAVs, to pick the layout.
- AirPods / Bluetooth headset: the preview survives the profile switch (`tapRestarts=1`).
- Owner decision: hide the panel from screen sharing and screenshots (`sharingType = .none`)? It
  shows patient text.

## Slices

- **S1 (pure logic, testable on Linux):** the setting key in `SettingsConfiguration` plus
  eligibility (`isLivePreviewAvailable(model:downloaded:)`), and a pure text merger that turns a
  stream of window hypotheses into `committed` + `tentative` text (no duplicated words at window
  overlaps). Unit tests for both. *(As built: the merger was replaced by the engine's own text;
  see "As built".)*
- **S2 (macOS):** `ParakeetLivePreview` in `ParakeetBackend.swift`, the `AVAudioEngine` tap, and
  the wiring in `MenuBarController`.
- **S3 (UI, written by Opus):** `LiveDictatePanel` and the settings toggle with its disabled state.
- **S4:** README `## Features` gets one line about the option. Localizable strings for the new copy.

## Verification (local Mac, not in the cloud)

- `bash scripts/run-tests.sh` green.
- `bash scripts/rebuild-and-restart.sh`, toggle on, Parakeet selected: dictate 60 s of German,
  see the text grow live, Stop pastes the same text as with the toggle off (compare both runs).
- Toggle off: no panel, no audio engine started (check logs).
- Whisper or a cloud model selected: toggle disabled with the caption.
- Esc during recording closes the panel.
- Screenshots of the panel in light and dark mode.

## Non-goals

Live insertion into the target app, live text for cloud models, live text for Meetings (they
have their own live transcript), changing the final-transcript path.
