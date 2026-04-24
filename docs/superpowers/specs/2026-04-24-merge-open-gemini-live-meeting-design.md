# Open Gemini + Live Meeting merge — design

**Status:** Approved for implementation planning (scope: minimal v1 as below).  
**Context:** Today, live meeting uses a **dedicated Meeting window** (`MeetingWindowManager`, `MeetingRootView`, `MeetingChatSplitView`) and a separate **Open Gemini** window (`GeminiRootView` → `GeminiChatView`). This spec merges the **user-facing** experience into **one** window and retires the standalone “Open Meeting” product surface.

**Out of scope (explicit non-goals for v1):** Separate Transcript and Summary **tabs** or **panes** in the Open Gemini window. Background recording, chunking, summarization, and file storage may still run as today; only **dedicated UI** to browse transcript/summary in-app is not required for v1.

---

## Goals

1. **Single window:** The user opens **Open Gemini** (shortcut / menu). There is **no** separate “Meeting” window for normal use.
2. **Meeting mode controls:** A **visible control** (e.g. toolbar, top-right) to **start** and **stop** live meeting recording, with a **clear “recording”** state while active.
3. **Commands:** **Slash commands** in the chat input to start and stop meeting mode (project convention: commands are typed in chat, e.g. `/meeting` / `/stop-meeting` — exact strings to be chosen during implementation, consistent with existing patterns).
4. **Chat + context:** While a meeting is active, the user chats with Gemini in the **normal full-width** chat. Gemini receives **meeting context** the same way as today’s `meetingContextProvider` path (rolling / recent transcript for the model), so the assistant can reason about what was said in the room.
5. **Control model:** **Start → Stop → Start** only. There is **no** pause-resume of the same in-progress session. **Stop** ends the current session (existing end-meeting behavior: persist, summary pipeline as implemented). The next **Start** begins a **new** session (new transcript / meeting identity), not a resume of the previous one.
6. **Settings:** All settings currently under **Live Meeting** (chunk interval, transcription model for meetings, summary model, safeguard, etc.) move into **Open Gemini** (or a sub-section of that settings area). The separate **“Open Meeting”** shortcut and its dedicated settings block are **removed**; opening the Gemini window is the single entry.
7. **What happens to the old Meeting window code:** The dedicated `MeetingWindowController` / `MeetingRootView` user flow is **replaced** by the merged experience. **Implementation** may delete or repurpose views; the spec only requires the **behaviors** above. If **meeting library**, **rename meeting**, or **browsing past meetings** remain product requirements, a follow-up iteration must place them in a **non-blocking** place (e.g. menu, command, or sheet) without reintroducing the old split layout by default (see *Deferred*).

---

## Non-goals (v1)

- **Transcript tab** and **Summary tab** in the Open Gemini window (the stakeholder does not use these today; v1 can omit dedicated UI).
- **Pause** as a first-class state distinct from **Stop**.
- Replicating the old **50/50 split** (`MeetingChatSplitView` layout) as the default meeting experience.

## Deferred (optional later)

- **Tabs** or a secondary view for **live transcript** and **rolling / final summary** in the same window, if user demand appears.
- **“Compile” / merge** transcript for export as an explicit action beyond what the pipeline already provides when stopping a meeting.
- **Pause-resume** of a single long session (needs clear semantics for chunks and file naming).

---

## User-facing text

All new UI labels, command descriptions, and settings copy must be in **English** (project rule).

---

## Success criteria (v1)

- User can open **Open Gemini**, start meeting recording from the **control** and/or **slash command**, and see that recording is active.
- User can **stop** from the same surfaces; after stop, **start** again begins a **new** meeting session.
- During recording, **Gemini chat** behaves like today’s “chat with meeting context” in terms of model access to live meeting text (same functional goal as `meetingContextProvider`-style context).
- **Settings** for live meeting behavior are reachable from **Open Gemini** settings, not a separate “Open Meeting” area.
- No second window is required to use live meeting with Gemini chat in v1.

---

## Risks and notes

- **Menu bar / global shortcuts** that today map to “open meeting” or “toggle live meeting” must be **migrated** so they do not open a dead window: either start/stop the merged flow or open Open Gemini and optionally start meeting—exact mapping is an implementation detail, but **no broken shortcuts**.
- **Regression risk:** Current Meeting window also hosts **library**, **past meetings**, and **end-meeting naming**. v1 may **temporarily** expose the library via a minimal path (e.g. menu command) or defer—must be an explicit **implementation plan** decision, not an accidental removal without replacement.

---

## Self-review (spec quality)

- **Placeholders:** None; scope is explicit about omitting transcript/summary UI in v1.
- **Consistency:** One window, start/stop/start model, settings consolidated under Open Gemini.
- **Ambiguity:** “Deferred” items are listed; v1 is intentionally minimal.
- **Scope:** Fits one implementation plan; large optional pieces are deferred.
