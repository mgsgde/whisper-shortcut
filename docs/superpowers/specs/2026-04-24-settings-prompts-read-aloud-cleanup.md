# Settings layout, per-mode prompts, Prompt Read removal, and Chat Read Aloud — design

**Status:** Draft for review.  
**Context:** Today, **Context** is its own Settings sidebar tab and bundles context data actions, a **single-file** editor for all `system-prompts.md` sections, and **Smart Improvement**. **Prompt Read Mode** exists in code and in the unified prompt file but is not a distinct user-facing shortcut path in the current menu flow. **Chat Read Aloud** (read a model reply via TTS from the chat UI) is separate from dictation and from the legacy “Prompt Read Mode” system prompt. Stakeholder wants a **cleaner Settings IA**, **mode-local prompt editing**, **removal of unused Prompt Read Mode**, optional **removal of Chat Read Aloud**, and **consistent naming** (“Dictate Prompt” instead of “Prompt Mode” in user-visible copy). **Default keyboard shortcut for opening Settings** is already updated in code to **⌘3** (with ⌘1 dictation and ⌘2 dictate prompt defaults unchanged in `ShortcutConfig`).

---

## Goals

### G1 — Remove Prompt Read Mode (product + code)

1. **Remove** the second prompt pipeline flavor **`PromptMode.promptAndRead`** / **`GenerationKind.promptAndRead`** and all dependent branches (Smart Improvement, context derivation, history, logging, suggested files).
2. **Remove** the **`=== Prompt Read Mode ===`** section from the canonical **`system-prompts.md`** format and from **`SystemPromptSection`**. When reading legacy user files, **ignore** unknown or legacy “Prompt Read” headers without crashing; on next canonical save, **omit** that section.
3. **Remove** UserDefaults keys that exist only for Prompt Read (e.g. `promptAndReadSystemPrompt`, `selectedPromptAndReadModel` in `UserDefaultsKeys.swift`) after migration or one-time read during file migration if still needed.

### G2 — Settings information architecture

1. **Remove** the **Context** entry from **`SettingsTab`** and the sidebar (`SettingsView.swift`, `SettingsConfiguration.swift`).
2. **Context data** (open folder in Finder, delete context data / interaction logs with confirmation): move to **General** (new or existing section; English copy).
3. **Smart Improvement** (save usage data, Improve from now, auto interval, improvement model, usage copy): move to **General** (dedicated section below or near other advanced items—exact vertical order is an implementation detail).
4. **Per-mode system prompt editing** (still backed by **one** `system-prompts.md` with `===` headers unless a later spec splits storage):
   - **Dictation** system prompt + **Whisper Glossary** (offline): edit in **Dictate** tab (`SpeechToTextSettingsTab.swift` or extracted subviews).
   - **Dictate Prompt** system prompt: edit in **Dictate Prompt** tab (`SpeechToPromptSettingsTab.swift`).
   - **Chat** system prompt: edit in **Chat** tab (`OpenGeminiSettingsTab.swift`).
5. Each per-mode editor: **Save**, **Revert**, **Open file** (opens `system-prompts.md` or the UserContext folder—behavior should match today’s Context tab pattern), reusing patterns from `ContextSettingsTab` / `PromptTextEditor` where applicable.
6. **Delete context data** confirmation must remain clear that **settings** are preserved; system prompts may reset per existing behavior—do not regress copy or safety.

### G3 — Naming: “Dictate Prompt” (not “Prompt Mode”)

1. All **user-visible** English strings, settings subtitles, Smart Improvement / derivation **prompt text** that still say **“Prompt Mode”** should say **Dictate Prompt** where they refer to the dictate-prompt feature.
2. **File header** for that section remains **`=== Dictate Prompt ===`**; keep **legacy read** mapping for **`=== Prompt Mode ===`** in `SystemPromptsStore` so existing files keep working until rewritten on save.
3. **Internal** Swift identifiers (e.g. `promptMode`, `GenerationKind.promptMode`) may stay for a smaller diff unless a follow-up rename is explicitly scoped.

### G4 — Chat Read Aloud removal (optional dedicated release slice)

1. **Remove** the **Read Aloud** control under assistant messages in **`GeminiChatView.swift`** (and related small views).
2. **Remove** notification observers **`geminiReadAloud`** / **`geminiReadAloudStop`** from **`MenuBarController.swift`** if they exist only for chat read-aloud.
3. **Remove** Chat-specific **Read Aloud** settings UI (**voice**, **TTS model**, **playback rate** if only used for chat read-aloud) from **`OpenGeminiSettingsTab.swift`** and **`ReadAloudVoiceSelectionView.swift`** when no longer referenced.
4. **Do not** remove **TTS** used for **live meeting** playback or other non–chat-read-aloud flows: **`SpeechService.readTextAloud`** / **`performTTS`** remain if still called from meeting or other product paths. If after analysis the **only** caller of a code path is chat read-aloud, that path may be deleted; otherwise narrow the removal to UI + notifications + chat-only settings keys.

### G5 — Default shortcuts (reference)

- **Already implemented:** **`ShortcutConfig.default.openSettings`** uses **⌘3**.
- **Existing defaults** in `ShortcutConfig.swift`: dictation toggle **⌘1**, dictate prompt **⌘2**, Open Gemini **⌥Space** (not ⌘Space). Changing Chat to **⌘Space** is **out of scope** for this spec unless added explicitly (Spotlight conflict on macOS).

---

## Non-goals

- **Splitting** `system-prompts.md` into multiple physical files (unless a follow-up spec requires it); editors may slice by section in memory.
- **Renaming** every internal `promptMode` symbol across the codebase in v1 (optional follow-up).
- **Migrating** existing users’ saved **Settings shortcut** from ⌘7 to ⌘3 automatically (already saved UserDefaults win over defaults).
- **Changing** Gemini chat **slash commands**, meeting UX, or merge spec in `2026-04-24-merge-open-gemini-live-meeting-design.md` except where this work **touches the same files**—then resolve conflicts in favor of **this** spec’s Settings/prompt goals.

---

## Phased delivery (commits)

Recommended **three** commits for reviewability (order agreed in conversation):

1. **Commit 1 — Prompt Read Mode removal**  
   G1 only; build green; manual smoke: Dictate Prompt, dictation, chat, Smart Improvement run without `promptAndRead`.

2. **Commit 2 — Settings IA + per-mode prompt editors + naming (G2, G3)**  
   Remove Context tab; relocate sections; string updates; build green.

3. **Commit 3 — Chat Read Aloud removal (G4)**  
   Isolated UI/TTS-notification/settings cleanup; verify live meeting TTS still works if applicable.

---

## User-facing text

All new or changed labels, subtitles, button titles, and confirmation bodies must be in **English** (project rule).

---

## Success criteria

- **No** **Context** tab; **General** contains context data + Smart Improvement; **Dictate**, **Dictate Prompt**, and **Chat** each expose the relevant **system prompt** (and glossary where specified) with save/revert/open file.
- **No** references in UI or improvement flows to **Prompt Read Mode** as a living feature; **no** `promptAndRead` in `GenerationKind` / scheduler / derivation.
- **Legacy** `system-prompts.md` with old headers still **loads**; saving produces a **valid** file without Prompt Read section.
- **Chat Read Aloud** (if Commit 3 is in scope): no button, no orphaned menu/notification handlers; meeting/other TTS **unchanged** where still required.
- **App builds** via existing script `bash scripts/rebuild-and-restart.sh` after each phase.

---

## Primary files (implementation hint)

| Area | Files (non-exhaustive) |
|------|-------------------------|
| Settings shell | `WhisperShortcut/SettingsView.swift`, `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift` |
| Tabs | `WhisperShortcut/Settings/Tabs/GeneralSettingsTab.swift`, `ContextSettingsTab.swift` (remove or shrink), `SpeechToTextSettingsTab.swift`, `SpeechToPromptSettingsTab.swift`, `OpenGeminiSettingsTab.swift` |
| Prompts file | `WhisperShortcut/SystemPromptsStore.swift`, `WhisperShortcut/AppConstants.swift` |
| Prompt Read removal | `WhisperShortcut/SpeechService.swift`, `WhisperShortcut/PromptConversationHistory.swift`, `WhisperShortcut/ContextLogger.swift`, `WhisperShortcut/ContextDerivation.swift`, `WhisperShortcut/AutoPromptImprovementScheduler.swift`, `WhisperShortcut/SmartImprovementTypes.swift`, `WhisperShortcut/UserDefaultsKeys.swift` |
| Read Aloud | `WhisperShortcut/GeminiChatView.swift`, `WhisperShortcut/MenuBarController.swift`, `WhisperShortcut/Settings/Components/ReadAloudVoiceSelectionView.swift`, `WhisperShortcut/Settings/Shared/SettingsViewModel.swift` |
| Shortcuts | `WhisperShortcut/ShortcutConfig.swift` (⌘3 already) |

---

## Open decisions (resolve during implementation)

- **Exact** section order inside **General** after relocation.
- Whether **“Open file”** on each sub-tab opens the **whole** `system-prompts.md` or only scrolls—acceptable v1: same as today (open file).
- After **Read Aloud** removal, whether **`UserDefaultsKeys`** entries for read-aloud voice/TTS rate are **removed** or left unused for one release (prefer clean removal with migration note in commit if keys are deleted).

---

## Spec self-review

- **Placeholders:** None intentional; open decisions are explicit.
- **Scope:** Three commits; Read Aloud is clearly separated so TTS for meetings is not accidentally removed without verification.
- **Consistency:** “Dictate Prompt” naming applies to **visible** strings; internal `promptMode` allowed for v1.
