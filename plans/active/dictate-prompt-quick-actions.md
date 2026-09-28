# Dictate Prompt Quick Actions

Owner decision 2026-09-28. Goal: run a frequent Dictate Prompt without speaking (library, open
office) and faster in general, while ⌘2 → speak → ⌘2 stays exactly as it is.

## Evidence

Local interaction logs, ~65 days, 435 `prompt` entries. After lowercasing and stripping
punctuation, five intents cover roughly 150 of them: "korrigiere" (~60 incl. typos),
"formuliere neu" (~45), "formatiere neu" (~21), "formuliere als to-do" (~12),
"formuliere/formatiere als e-mail" (~9). Exact counting after normalization already yields the
right top 5 — no LLM clustering.

## Behaviour

1. ⌘2 starts the prompt recording **immediately, unchanged**. In addition a small quick-action
   list appears attached to (directly above) the recording pill: up to 5 entries, numbered 1–5,
   entry 1 (most frequent) preselected/highlighted.
2. While that list is visible:
   - **Return** → run the highlighted quick action.
   - **↑ / ↓** → move the highlight. **1–5** → run that entry directly.
   - **Esc** → hide the list only; the recording keeps running.
   - Clicking an entry runs it.
   - Speaking and pressing ⌘2 again → normal voice flow; the list disappears with the recording.
3. Running a quick action stops the recording and runs the **same** prompt job
   (`performPrompting` → `runAudioJob`: paste, popup, cancellation, errors), except the model gets
   the entry's text as the instruction instead of the audio. The audio is never sent and never
   transcribed. The silence / too-short precheck must not reject it.
4. The list is not shown during a live-meeting prompt segment (keep that path untouched), and not
   when there are zero entries.

## Where the entries come from

- New `QuickActionStore` (or similar, one file): reads `ContextLogger.shared` interaction logs of
  the last 30 days, `mode == "prompt"`, key = `userInstruction` normalized (lowercase, trim,
  strip trailing/leading punctuation `.,!?;:`, remove filler tokens `ähm`, `äh`, `ehm`, `um`,
  `uh`, collapse whitespace). Skip empty keys, the `voiceInstructionPlaceholder`, and keys longer
  than 60 chars (one-off prompts). Count, take top 5 with count ≥ 2. Display text = the most
  frequent original spelling of that key, trimmed, trailing period removed, first letter
  uppercased.
- Computed off the main thread, cached, refreshed after each completed prompt and at launch —
  never read synchronously from disk on the ⌘2 path.
- **Fallback** when logging is disabled / Offline Mode / fewer than 3 entries found: fill up to 5
  with built-in defaults (English, user-facing rule): "Fix grammar and spelling", "Rewrite more
  clearly", "Make it shorter", "Format as a to-do", "Translate to English". Learned entries first.
- Running a quick action logs the prompt with `userInstruction` = the entry text (via the existing
  `recordPromptTurn(.known(text))`), so usage reinforces itself.

## Implementation notes

- **Key input without stealing focus.** `RecordingIndicatorPanel.canBecomeKey` is `false` on
  purpose (focus stays in the target app so auto-paste lands there). Keep that. Capture keys with
  temporary Carbon hotkeys via the `HotKey` package the app already uses: register Return, Escape,
  Up, Down, 1–5 (no modifiers) when the list appears; unregister when it hides, when the recording
  ends for any reason, and on quick-action run. No CGEventTap (that needs Accessibility, which the
  App Store build avoids).
- **SpeechService:** give `executePrompt` / `performPrompt` an optional text instruction
  (e.g. `instruction: String? = nil`). When set: skip `validateAudioFileFormat` and all audio
  parts; Gemini sends a text part `VOICE INSTRUCTION:\n<text>` (mirror the local path's user-text
  shape) after the envelope parts; OpenAI sends it as a text content part instead of
  `input_audio`; local skips `performTranscription` and uses the text. Record with
  `.known(text)`, not `.parallelTranscription`. The `supportsDictatePrompt` guard stays (keep
  behaviour identical per provider; no new provider support in this slice).
- **MenuBarController:** on quick action, remember the instruction keyed by the recording's audio
  URL (so the retry closure re-runs with the same instruction), stop the recording through the
  normal stop path, and in `performPrompting` pass it to `executePrompt`. Bypass the silence
  precheck for that URL.
- README `## Features` → Dictate Prompt bullet: one sentence on quick actions (the in-app Chat
  reads it).

## Out of scope (later, only if asked)

Pinning/hiding entries in Settings, a settings toggle, LLM clustering of synonyms, meeting
segments.
