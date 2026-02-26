---
name: ""
overview: ""
todos: []
isProject: false
---

# System prompt for Gemini Chat and Approve from Usage

## Naming (no "User Context")

- **Do not** use "User Context" for this feature. In the codebase that term refers to the old, removed section; technically the new feature is the same thing: **system instruction / system prompt for Gemini**.
- **Use instead**: "System prompt for Gemini Chat" or "Additional instructions for Gemini Chat" – i.e. the system prompt that controls the Open Gemini chat window (language, style, rules, and optionally who the user is: name, location, projects).
- **Cleanup**: Change the remaining UI string "improve prompts and user context by voice" to "improve prompts by voice" so "User Context" is no longer used in the app.

---

## Current state (from code)

- "User Context" as a separate feature **no longer exists**. In [ContextLogger](WhisperShortcut/ContextLogger.swift): "User Context section was removed from system prompts" – `loadUserContext()` returns `nil`.
- Open Gemini Chat ([GeminiChatView](WhisperShortcut/GeminiChatView.swift)) uses a **fixed** `openGeminiSystemInstruction` – no user-editable context, no `user-context.md`.
- What exists: **Context data** (folder/logs), **System prompts** (`system-prompts.md` for Dictation, Prompt Mode, Prompt & Read). The folder is still named "UserContext" internally (compatibility).

---

## Goals

1. **System prompt for Gemini Chat**: One user-editable system prompt that controls the chat window (persona, style, guardrails, and optionally user info: name, location, role, projects like Whisper Shortcuts, Sabaki Dance). Stored like the other system prompts (see storage option below).
2. **Consistency**: Same structure as other modes (Persona → Task → Guardrails → Output; [gemini-system-prompt-best-practices](.cursor/skills/gemini-system-prompt-best-practices/SKILL.md)).
3. **Approve from Usage**: Smart Improvement ("Improve from usage" and optionally "Improve from voice") can suggest and apply updates to this **Gemini Chat system prompt** via the same review panel flow as Dictation, Prompt Mode, and Prompt & Read.

---

## 1. Storage: Gemini Chat system prompt

**Option A (recommended)**  

- Add a fourth section to [SystemPromptsStore](WhisperShortcut/SystemPromptsStore.swift): e.g. `SystemPromptSection.geminiChat` with header `"=== Gemini Chat ==="`. Store in the same `system-prompts.md` file. No separate file; same load/save/editor as other prompts. "Open file" in Context tab already opens `system-prompts.md` – the new section is just another block there.

**Option B**  

- Keep a dedicated file (e.g. `gemini-chat-system-prompt.md` in UserContext). Requires separate load in [ContextLogger](WhisperShortcut/ContextLogger.swift) or a small dedicated store, and either a second editor or "Open file" for that file only.

**Recommendation**: Option A – one file, one editor, one mental model: "all system prompts in one place (Dictation, Prompt Mode, Prompt & Read, Gemini Chat)."

---

## 2. Gemini Chat: use the stored system prompt

- In [GeminiChatView](WhisperShortcut/GeminiChatView.swift): Replace the static `openGeminiSystemInstruction` with a **dynamic** instruction built from the **Gemini Chat** system prompt:
  - Load from `SystemPromptsStore.shared.loadSection(.geminiChat)` (if Option A) or from the dedicated loader (if Option B). If missing or empty, fall back to the current default (existing "In short:", headings with emojis, etc.) – either in code or as the default content for the new section in `defaultFormattedContent()`.
  - Build the `[String: Any]` system instruction once per send (or when the chat loads) and pass it to `apiClient.sendChatMessage(..., systemInstruction: ...)`.
- No separate "user context" block; the single **system prompt for Gemini Chat** can include who the user is (name, location, projects) as part of the prompt text.

---

## 3. Context tab and Settings

- **System prompts**: If Option A, the existing System prompts editor in [ContextSettingsTab](WhisperShortcut/Settings/Tabs/ContextSettingsTab.swift) already shows the full `system-prompts.md`; add the new "=== Gemini Chat ===" section to [SystemPromptsStore](WhisperShortcut/SystemPromptsStore.swift) default content and parsing so the section appears and is saveable.
- **No** separate "User context" section or "Open user context file" – only the single system prompts file (and optionally a short subtitle that "Gemini Chat" is the system prompt for the Open Gemini chat window).
- **Cleanup**: In Context tab (or wherever the string lives), change "improve prompts and user context by voice" to **"improve prompts by voice"**.

---

## 4. Approve from Usage for Gemini Chat system prompt

- Add **Gemini Chat** as a fourth focus:
  - In [SettingsViewModel](WhisperShortcut/Settings/Shared/SettingsViewModel.swift): Add `case geminiChat` to `GenerationKind` with display name e.g. "Gemini Chat System Prompt".
  - In [ContextDerivation](WhisperShortcut/ContextDerivation.swift): Support focus `geminiChat` – same pattern as dictation/promptMode/promptAndRead: request to Gemini with markers, extract suggested text, write to a suggested file (e.g. `suggested-gemini-chat-system-prompt.txt`).
  - In [AutoPromptImprovementScheduler](WhisperShortcut/AutoPromptImprovementScheduler.swift): Include `geminiChat` in the foci for "Improve from usage" (and optionally "Improve from voice"). Implement `hasSuggestion`, `readSuggestion`, `currentContent`, `discardSuggestion`, `applySuggestion` for `geminiChat`: current content from `SystemPromptsStore.loadSection(.geminiChat)` (Option A), suggested from the new suggested file; on apply, update section and append to system prompt history (reuse existing mechanism; no separate user-context-history).
- In [ContextLogger](WhisperShortcut/ContextLogger.swift): Add `deleteSuggestedGeminiChatSystemPromptFile()` (and optionally stop referencing "suggested-user-context" / "user context" in comments if we fully drop that concept). No need to restore `loadUserContext()` or `user-context.md` for this feature.

---

## 5. Files to touch (summary)

| Area                           | Files                                                                                                                                                                                                                                                                            |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| System prompt storage          | [SystemPromptsStore.swift](WhisperShortcut/SystemPromptsStore.swift) (new section `geminiChat`, default content)                                                                                                                                                                 |
| Gemini Chat uses stored prompt | [GeminiChatView.swift](WhisperShortcut/GeminiChatView.swift)                                                                                                                                                                                                                     |
| Context tab / UI string        | [ContextSettingsTab.swift](WhisperShortcut/Settings/Tabs/ContextSettingsTab.swift) ("improve prompts by voice")                                                                                                                                                                  |
| Derivation + scheduler         | [ContextDerivation.swift](WhisperShortcut/ContextDerivation.swift), [AutoPromptImprovementScheduler.swift](WhisperShortcut/AutoPromptImprovementScheduler.swift), [SettingsViewModel.swift](WhisperShortcut/Settings/Shared/SettingsViewModel.swift) (GenerationKind.geminiChat) |
| Suggested file cleanup         | [ContextLogger.swift](WhisperShortcut/ContextLogger.swift) (new delete for suggested Gemini Chat prompt file; optional comment cleanup)                                                                                                                                          |

---

## 6. Language and rules

- All new UI strings and comments in **English**.
- Use **DebugLogger** only.
- After implementation: run `bash scripts/rebuild-and-restart.sh` once.
