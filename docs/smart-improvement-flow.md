# Smart System Prompt Improvement – Flow (current)

This document describes how the smart system prompt improvement currently works: triggers, conditions, pipeline, and automatic application of suggestions.

---

## 1. Overview

The "Smart Improvement" runs automatically in the background and generates suggestions for system prompts and user context. Suggestions are **applied automatically**: the generated text is written directly into the active settings (UserDefaults or `user-context.md`). A popup briefly informs the user ("Auto-improved: … Check Settings to review or revert."). The user can review or edit the result in the relevant settings tabs.

---

## 2. When is it triggered?

There is a single trigger: **after successful dictations**.

In `MenuBarController.swift`, after each successful transcription `incrementDictationCountAndRunIfNeeded()` is called.

**First run ever** (no previous improvement run): an improvement run is started when the dictation counter reaches the threshold (N) and there is at least some interaction data (any age). No 7-day minimum and no cooldown apply, so new users get their first improvement quickly after N dictations.

**Subsequent runs**: an improvement run is started when **all** of the following are met:

1. **Dictation threshold reached** – The counter of successful dictations has reached the configurable threshold (default: 2, configurable to 2/5/10/20/50 in Settings).
2. **Cooldown expired** – At least as many days have passed since the last run as the selected interval. With "Always" there is no cooldown.
3. **Minimum usage history** – There is interaction data at least **7 days old** (oldest interaction log file is ≥ 7 days). This avoids running improvements before the user has enough history; with only recent usage (e.g. 2 dictations today), the run is skipped and the log says: *"Skip - need at least 7 days of data"*.

If the threshold is reached but the cooldown is still active, the counter is not reset and is checked again on the next dictation.

**Manual trigger:** A **"Run improvement now"** button is available in Settings → Smart Improvement. It runs the same pipeline (all four foci, apply suggestions, update last run date) but ignores cooldown, interval, and dictation count. Preconditions: API key and at least some interaction data (any age).

---

## 3. Conditions for a run

The following checks must be satisfied in `incrementDictationCountAndRunIfNeeded()`:

- **Interval** ≠ "Never" (i.e. Smart Improvement is enabled).
- **Google API key** is set.
- **First run ever**: Only the **dictation threshold** (N) and the presence of some interaction data (any age) are required. No 7-day minimum and no cooldown.
- **Subsequent runs**:
  - **Minimum usage**: At least **7 days** of interaction data (`autoImprovementMinimumInteractionDays`) when interval is 3/7/14/30 days. This is based on the **oldest** interaction log file date (see "Skip - need at least 7 days of data" in logs). With interval "Always", no minimum days are required.
  - **Dictation threshold** reached (configurable: 2/5/10/20/50).
  - **Cooldown** expired (interval: Always/3/7/14/30 days).

Logging and auto-apply are **implicitly** enabled when the interval is set to a value ≠ "Never". There are no separate checkboxes for them.

---

## 4. Settings

In the Smart Improvement settings tab there are three options:

| Setting | Options | Meaning |
|---------|---------|---------|
| **Model for Smart Improvement** | Gemini 2.0 Flash, 2.5 Flash, 2.5 Flash-Lite, 3 Flash, 3.1 Pro, etc. | Gemini model used for automatic Smart Improvement and for "Generate with AI" in settings. Default: Gemini 3.1 Pro. |
| **Automatic system prompt improvement** | Never, Always, Every 3/7/14/30 days | Enables/disables Smart Improvement. The value is the minimum cooldown between runs. "Always" = no cooldown. |
| **Improvement after N dictations** | 2, 5, 10, 20, 50 | Number of successful dictations after which an improvement run is triggered (provided cooldown has expired). |
| **Run improvement now** | Button | Manual trigger: runs the improvement pipeline immediately; ignores cooldown and dictation count. Requires API key and some interaction data. |

---

## 5. Flow of an improvement run

In `runImprovement()` the following happens:

1. **`UserContextDerivation`** is invoked for four foci in sequence:
   - **User Context** – User profile (language, topics, style, terminology).
   - **Dictation** – System prompt for **Speech-to-Text** (transcription).
   - **Prompt Mode** – System prompt for **"Dictate Prompt"** (voice → instruction on clipboard text).
   - **Prompt & Read** – System prompt for **"Prompt & Read"** (instruction + read aloud).

2. **For each focus**:
   - **Log collection**: `UserContextLogger` provides interaction logs (JSONL); **tiered sampling** is used (e.g. 50% last 7 days, 30% 8–14, 20% 15–30), limited by entries per mode and total characters.
   - **Gemini call**: The collected text (plus optional existing user context / current prompts) is sent as a user message to **Gemini** using the **selected improvement model** (see Settings; default: Gemini 3.1 Pro). The **system prompt** for Gemini is fixed per focus (in `UserContextDerivation.systemPromptForFocus(_:)`) and requires a response with exact markers (e.g. `===SUGGESTED_SYSTEM_PROMPT_START===` … `===END===`).
   - **Parsing**: The content between the markers is extracted from the Gemini response.
   - **Writing**: The extracted text is written to a **suggestion file** in the context directory:
     - `suggested-user-context.md`
     - `suggested-dictation-prompt.txt`
     - `suggested-prompt-mode-system-prompt.txt`
     - `suggested-prompt-and-read-system-prompt.txt`

3. **After the run**:
   - All foci for which a **non-empty** suggestion file exists are recorded as successful.
   - Each suggestion is applied immediately via `applySuggestion(_:for:)`: current value is stored as "Previous", new value is written to UserDefaults or `user-context.md`, suggestion file is deleted.
   - A **popup** shows: "Auto-improved: User Context, Dictation Prompt, … Check Settings to review or revert."
   - `lastAutoImprovementRunDate` is set (even if no suggestions were generated).
   - Dictation counter is reset to 0.

---

## 6. Where suggestions are applied

Suggestions are applied immediately to the active settings:

| Focus | Target | Previous key |
|-------|--------|--------------|
| User Context | `user-context.md` (file) | `previousUserContext` |
| Dictation | `customPromptText` (UserDefaults) | `previousCustomPromptText` |
| Prompt Mode | `promptModeSystemPrompt` (UserDefaults) | `previousPromptModeSystemPrompt` |
| Prompt & Read | `promptAndReadSystemPrompt` (UserDefaults) | `previousPromptAndReadSystemPrompt` |

The user can review or edit the applied values in the respective Settings tabs.

---

## 7. Summary

| Aspect | Implementation |
|--------|-----------------|
| **Trigger** | After N successful dictations (configurable: 2–50), provided cooldown has expired **and** interaction data is at least 7 days old. |
| **Cooldown** | Minimum interval between runs: Always (no cooldown), 3, 7, 14, or 30 days. |
| **Data basis** | Interaction logs (JSONL) from `UserContextLogger`, tiered sampling, character/entry limits. |
| **AI** | User-selectable Gemini model (Settings > Smart Improvement); fixed system prompt per focus; response with markers. |
| **Output** | Suggestions are applied automatically (Previous saved, popup "review or revert"). |

---

## Reference: relevant files

- `AutoPromptImprovementScheduler.swift` – Scheduler, cooldown, counter, `runImprovement()`, `applySuggestion()`
- `AutoImprovementInterval.swift` – Enum: Never, Always, 3/7/14/30 days
- `UserContextDerivation.swift` – Log sampling, `systemPromptForFocus`, Gemini call, writing suggestion files
- `UserContextLogger.swift` – Interaction logs (JSONL)
- `FullApp.swift` – App launch: `checkForPendingSuggestions()`
- `MenuBarController.swift` – `incrementDictationCountAndRunIfNeeded()` after successful transcription
- `SettingsViewModel.swift` – `GenerationKind`, Compare Sheet, Apply/Dismiss
- `GeneralSettingsTab.swift` – Settings UI for improvement model, interval, and dictation threshold
- `AppConstants.swift` – `autoImprovementMinimumInteractionDays`, `promptImprovementDictationThreshold`, sampling constants; `userContextDerivationEndpoint` used as fallback when no valid model is selected
- `UserDefaultsKeys.swift` – All relevant keys (`selectedImprovementModel`, `autoPromptImprovementIntervalDays`, `promptImprovementDictationThreshold`, etc.)
