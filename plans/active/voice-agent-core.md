# One Agent Core for Chat and Dictate Prompt (D11)

**Status:** Slices 1–3 done (2026-09-29). Slice 3 (this change) extends the agent path to OpenAI
GPT-Audio (Chat Completions with `input_audio`, only when the recording is attached — the model
rejects audio-less input) and to a local server (Ollama / LM Studio, transcript in). In-process MLX
has no tool-calling path and keeps the single request. In Offline Mode only the shared-folder tools
are offered. Still open: tool records in the Dictate Prompt history (`PromptConversationHistory`
stores text only); a live test against a local server (none was running when this shipped).
Deviation from decision 1: **no web grounding** on any Dictate Prompt path — Gemini's grounding
also enables `url_context`, an exfiltration path for instructions planted in a selection or email.
**Audience:** LLM implementing it end-to-end, one slice per PR.
**Origin:** app review 2026-09-29, recommendation D11.

---

## Why

- The tool loop lives inside `ChatViewModel.performSend` (`ChatView.swift`), tangled with the
  streaming bubble, the tool-steps buffer, session persistence and the watchdog. Nothing outside
  the chat window can run it.
- Dictate Prompt is a separate pipeline (`SpeechService.executePrompt` + `DictatePromptEnvelope`,
  refactor ledger R5). It has no tools: "rewrite this reply and put my Thursday slot in" cannot
  look at the calendar, "fill in the ticket number from the Trello card" cannot read Trello.
- Two pipelines means every agent improvement (tool history, caching order, approval, loop
  guards) is built for one and missing from the other.

## Target shape

```
ChatAgentRunner (UI-free, @MainActor)
  inputs:  provider, model, contents, system instruction, tool declarations, options,
           tool executor (ChatToolRegistry + session handlers), approval policy, max rounds
  output:  AsyncStream<AgentEvent>  — .textDelta, .activity, .step(ChatToolStep), .finished(reply, records, sources)
ChatViewModel      → adapter: feeds events into StreamingBuffer / ToolStepsBuffer / session store
Dictate Prompt     → adapter: collects the final text, pastes it; steps go to the pill label
```

The loop guards move with it unchanged: round cap + final tool-less round, `ChatStreamLoopGuard`,
`ChatToolTurnMemo`, tool records (`ChatToolHistory`), approval via an injected policy.

## Slice 1 — Extract the runner (behaviour-neutral)

- Move the loop body of `performSend` and `executeToolCalls` into `ChatAgentRunner`. Approval
  becomes a closure `(ChatToolStep) async -> Bool` so the chat keeps its inline card.
- `ChatViewModel.performSend` keeps: placeholder message, buffers, persistence, title generation,
  error presentation. It consumes the runner's events.
- Tests with a fake `LLMChatProvider` (scripted events): text-only turn; two tool rounds; round
  cap reached → final tool-less round; denied approval; cancellation mid-tool.
- Done when: chat behaves identically (existing tests + manual: Gmail search, calendar create with
  approval, Stop mid-loop), `ChatView.swift` loses the loop (refactor ledger R3 progress).

## Slice 2 — Dictate Prompt runs on the runner

- Contents: the Dictate Prompt envelope (selection, clipboard header, screenshot, history) becomes
  the runner's `contents`. Audio stays native where the provider takes it (R5's measured reason):
  Gemini `inline_data` / Files API, OpenAI `input_audio`; providers without audio input get the
  transcript, as today.
- Tools: see decisions below. Tool steps drive the pill label ("Checking calendar…").
- Output: the final reply text is pasted exactly as today; tool records are kept in the prompt
  history so a follow-up Dictate Prompt still knows the IDs.

## Decisions (settled 2026-09-29)

Magnus: „Ja, nimm deine Empfehlungen für D11" — so all three recommendations below apply.


1. **Which tools may Dictate Prompt use?** Recommendation: read-only only (calendar/tasks list,
   Gmail search/read, Trello read, workspace read, web grounding). Mutating tools would raise an
   approval prompt in the middle of a paste flow, and the result of Dictate Prompt is text, not
   an action.
2. **Round cap.** Recommendation: 3 tool rounds (chat: 16). Each round adds a provider round
   trip; Dictate Prompt is a latency-sensitive paste.
3. **Opt-in or default?** Recommendation: on by default for connected integrations only, with a
   Settings → Dictate Prompt toggle.

## Falsifier

After slice 2 ships: share of Dictate Prompt runs that call ≥1 tool, and Dictate Prompt p50
latency for runs without a tool call must not rise by more than 200 ms versus the release before
(both from the interaction log). If no run calls a tool within 30 days of release, slice 2 was
not worth its complexity — revert to the envelope pipeline.
