# Voice Feedback — Edit the Dictation Context by Speaking

**Status:** Slices 1, 2 & 3 implemented (2026-07-24). Shortcut defaults to **⌘5** (`ShortcutConfig.voiceFeedback`), now **editable** in Settings → Smart Improvement ("Voice Feedback" recorder row) and listed in the Shortcuts overview. Menu item "Voice Feedback". Flow works end-to-end: ⌘5 → record → transcribe → `VoiceFeedbackService.proposeChange` (improvement model, structured output with `target_section`) → `SmartImprovementReviewPanel` → on Accept `updateSection` + `appendSystemPromptsHistory(source: "voice-feedback")`. Log markers `VOICE-FEEDBACK:` / `VOICE-FEEDBACK-CHANGE:`. The toggle now pre-checks **both** the transcription credential and the improvement-model credential (via `loadPromptModel`, matching `ContextDerivation`), so a missing key is reported before recording — the earlier V1 gap is closed.

Slice 3 touch points: `SettingsDefaults.voiceFeedback` + `SettingsData.voiceFeedback` + `SettingsFocusField.voiceFeedbackShortcut` (`SettingsConfiguration.swift`); load-mapping + `configurableShortcutSlots` slot + save path (`SettingsViewModel.swift`, replacing the loadConfiguration hack); `ShortcutRecorderRow` + `@FocusState.Binding` in `ImprovementSettingsTab` with call-site update in `SettingsView`; `ShortcutsOverviewSection` row. Voice Feedback is available in the App Store build too (normal Carbon hotkey, so no `#if !APP_STORE` gate).
**Audience:** LLM implementing the feature end-to-end
**Goal:** Give the user an explicit, user-initiated way to teach/correct the dictation context by *speaking*, instead of waiting for the periodic Smart Improvement log-miner to infer the same thing statistically. Press a shortcut, say something like *"you keep mistranscribing my name — it's spelled G-ö-d-d-e"* or *"stop capitalizing every noun in Dictate Prompt output"*, and the app turns that instruction into a concrete, reviewable change to `system-prompts.md`.

---

## Why this exists (the problem it solves)

Today's Smart Improvement is a **passive, statistical** learner: 7-day cadence, mines JSONL logs, requires ≥2 recurrences before it will change anything (`AppConstants.smartImprovementMinPerFocusInteractions = 20`, evidence rule inside `ContextDerivation`). That design is exactly why it fails the cases we've logged:

- **Names aren't learned** when misspellings are inconsistent — per-token ≥2 recurrence never triggers (memory: *smart-improvement-name-not-learned*).
- **Sample starvation** — a ~15–20 entry sample vs. the evidence bar means `no_change` dominates (memory: *smart-improvement-sample-starvation*).

An **explicit spoken correction is a single high-signal event** that bypasses all of that statistical fragility. This feature is a *third* learning channel, complementary to the two that exist:

1. Periodic batch — `AutoPromptImprovementScheduler` + `ContextDerivation` (7-day, mines logs).
2. Fast loop — `GlossaryFastLearner` (silent, learns glossary terms from typed chat text + the `remember_dictation_term` chat tool).
3. **Voice feedback (this plan)** — spoken, on-demand, human-reviewed.

## Design decisions (made; revisit only with evidence)

- **Own shortcut, not FN, not intent-detection on the transcript.** Overloading Dictate (FN) would force the app to guess "is this dictation or meta-feedback?" and mis-routes land verbatim in the user's document. A dedicated mode removes that entire failure class. FN is also hard-wired to Dictate today (`FnPushToTalk.swift`) and disabled in the App Store build, so it's a poor host. Default binding: a free slot (⌘5 is unused; confirm against `ShortcutConfig` defaults at build time).
- **Human-in-the-loop review, never silent prompt mutation.** The spoken instruction becomes a *staged, editable* change shown in the existing `SmartImprovementReviewPanel` (diff + rationale + editable suggestion). Accept writes; Cancel does nothing. This reuses the exact guardrail UI the batch path already has.
- **Reversible.** Apply goes through the same `updateSection` + `appendSystemPromptsHistory` path as the batch, so the change lands in the system-prompts history and can be reverted by editing the file in Settings. No new undo mechanism in V1.
- **Persistent context change only (V1).** "Teach me this for next time." The *one-shot* variant ("fix the text I just pasted") is a separate feature with its own paste path — explicitly out of scope (see Non-goals).
- **The LLM routes the change to the right section.** The user won't say "put this in the Whisper Glossary." The model decides `targetSection ∈ {dictation, whisperGlossary, promptMode, chat}` and returns a structured suggestion. Reuse `SystemPromptSection` (`SystemPromptsStore.swift:12`).
- **Recent interactions are part of the prompt context.** "You just got that wrong" needs a referent. Feed the last ~10 `InteractionLogEntry`s (esp. the most recent dictation result) from `ContextLogger.interactionLogFiles(lastDays:)` so relative complaints resolve. Gate on `contextLoggingEnabled` — if usage logging is off, skip the recent-context block (the feature still works from the spoken instruction alone).
- **Cloud-only V1.** The instruction→change reasoning wants a capable model. Route to the same provider/model the batch uses (`improveFromUsage` model picker). Requires a credential; if none, show the standard error popup.

## The flow

```
⌘5 (new shortcut, push-to-talk like Dictate)
  → record audio  (RecordingIndicator pill, inherited from appState)
  → stop
  → SpeechService.executeVoiceFeedback(audioURL:)      // new, models executePrompt
       systemPrompt = current system-prompts.md sections
                    + last ~10 interaction log entries (if logging on)
                    + instruction to return structured output
       structured output: { targetSection, decision, suggestion, rationale }
  → if decision == no_change → info popup "No change suggested", done
  → else → SmartImprovementReviewPanel.present(diff, rationale, editable suggestion)
       Accept → SystemPromptsStore.updateSection(targetSection, editedSuggestion)
              + ContextLogger.appendSystemPromptsHistory(...)
              + log VOICE-FEEDBACK-CHANGE
       Cancel → nothing
```

Feedback UI is automatic: the recording/processing pill comes from `appState` (`RecordingIndicatorManager`), errors from `PopupNotificationWindow`. No new UI component needed beyond reusing the review panel.

## Reused building blocks (nothing here is new)

| Piece | Existing component | Reuse notes |
|---|---|---|
| Push-to-talk recording | `Shortcuts.swift` hold logic + `AudioRecorder` | New shortcut inherits push-to-talk for free |
| Audio→LLM structured call | `SpeechService.executePrompt` / `performPrompt` (`SpeechService.swift:361/402`) | Model `executeVoiceFeedback` on this; AAC transcode + retries + provider branch come along |
| Structured output schema | `ContextDerivation.analysisSchema` (`ContextDerivation.swift:50`) | Extend `{decision, suggestion, rationale}` with `targetSection` |
| Review modal | `SmartImprovementReviewPanel.present` (`SmartImprovementReviewView.swift:223`) | Same diff/rationale/editable-suggestion UI as the batch |
| Apply + history | pattern from `AutoPromptImprovementScheduler.applySuggestion` (`:367`) | `updateSection` + `appendSystemPromptsHistory` + change log |
| Recent-interaction context | `ContextLogger.interactionLogFiles(lastDays:)` | Feed last ~10 entries into the prompt |
| Section model | `SystemPromptSection` (`SystemPromptsStore.swift:12`) | `targetSection` maps 1:1 |

## Implementation slices (each independently shippable)

1. **Shortcut + mode plumbing (no LLM yet).** Add the binding and route a recording end-to-end that just logs the transcript.
   - `ShortcutConfig`: new field + default + UserDefaults key (`ShortcutConfig.swift:106-121, 271-278, 316-344`).
   - `Shortcuts.swift`: HotKey property, `setupShortcuts` block, `cleanup()`, `ShortcutDelegate` method.
   - `AppState.RecordingMode`: new case + icon/statusText/tooltip + `stopRecording()` mapping (`AppState.swift:22-50, 278-289, 340-348`).
   - `MenuBarController`: `toggleVoiceFeedback()` (model `togglePrompting` `:730`), new arm in `audioRecorderDidFinishRecording` switch (`:2287-2304`), `performVoiceFeedback(audioURL:)` stub, `stopCurrentOperation()` path, `ShortcutDelegate` forwarding (`:2336-2353`).
   - Menu entry in `createMenu()` (`:198-224`).
   - **Verify:** shortcut records, pill shows, transcript appears in logs. No context change yet.

2. **LLM instruction→change + review.** Wire the real reasoning.
   - `SpeechService.executeVoiceFeedback(audioURL:)` — build the feedback system prompt (current sections + recent interactions + instruction), call the batch model with structured output including `targetSection`.
   - Extend the schema with `targetSection`.
   - `performVoiceFeedback`: on `no_change` → info popup; else present `SmartImprovementReviewPanel`; Accept → `updateSection` + history + `VOICE-FEEDBACK-CHANGE` log.
   - **Verify:** the "Gödde" case — speak the correction once, confirm a whisperGlossary suggestion appears, Accept, confirm `system-prompts.md` gained the entry and next dictation uses it.

3. **Settings + polish.**
   - `ShortcutRecorderRow` in `ImprovementSettingsTab` (feature lives next to Smart Improvement), `SettingsData` field + defaults, `SettingsFocusField` case, `configurableShortcutSlots` registration (`SettingsViewModel.swift:214-233`).
   - Short helptext explaining the mode.
   - Cooldown/guard against double-fire if needed (mirror the batch's cooldown constant).
   - **Verify:** shortcut editable in Settings, persists, overview row shows it.

## Non-goals

- **No one-shot text correction.** "Fix the text I just pasted" is a different feature (needs re-paste of a corrected string, not a context edit). Out of V1.
- **No FN double-binding.** V1 uses a normal Carbon shortcut. Fn+modifier is a later question if wanted.
- **No offline/local-model path.** The instruction→change reasoning is cloud-only in V1.
- **No silent apply.** Every change goes through the review modal — that's the whole guardrail.
- **No new review UI.** Reuse `SmartImprovementReviewPanel` as-is; don't fork it.

## Verification

- Rebuild + restart via `bash scripts/rebuild-and-restart.sh` after each slice.
- Manual repro for slice 2: the logged failure cases — speak a name correction and a Dictate-Prompt style rule; confirm each routes to the right section, the diff is sane, Accept persists, Cancel is a no-op.
- Confirm the change survives a restart (it's in `system-prompts.md`) and is picked up by the next dictation (glossary injection via `SpeechService.appendGlossaryHint`).
- Confirm `contextLoggingEnabled == false` still allows the feature (just without the recent-interaction context block).
- Log markers: `VOICE-FEEDBACK:` (flow) and `VOICE-FEEDBACK-CHANGE:` (applied change), mirroring `SYSTEM-PROMPT-CHANGE`.

## Open questions for the user

- **Binding:** OK to default to ⌘5 (or your preferred free slot)?
- **Spoken confirmation?** V1 is silent-apply-after-review (visual modal only). Do you also want the app to *speak back* what it changed (reuse the Read Aloud TTS pipeline)? Cheap to add later; left out of V1 for focus.
