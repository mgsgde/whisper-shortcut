---
name: gemini-system-prompt-best-practices
description: Applies official Google best practices when writing or editing Gemini system prompts (systemInstruction). Use when creating or changing system prompts for Gemini (e.g. transcription, Dictate Prompt, Prompt & Read), when reviewing prompt text in AppConstants or SpeechService, or when the user asks about Gemini prompt design.
---

# Gemini System Prompt Best Practices

When writing or editing **system prompts** for Gemini (especially 2.0 Flash), apply these practices. They are derived from official Google documentation so model behavior stays predictable and output quality is high.

## When to Use This Skill

- Adding or changing `systemInstruction` / system prompt text (e.g. in `AppConstants`, `SpeechService`, or settings).
- Reviewing or refactoring existing system prompts (transcription, Dictate Prompt, Prompt & Read).
- User asks how to improve a Gemini system prompt or about best practices.

## Structure of a Good System Prompt (Order Matters)

Build the system prompt in this order:

1. **Persona / role**  
   Who the model is (e.g. "You are a professional transcription service" or "You are a text editing assistant"). Include output language or style if relevant.

2. **Task and rules**  
   What to do and how. Prefer clear, ordered rules. Separate:
   - One-time or setup rules (e.g. "The first input is selected text, the second is the voice instruction").
   - Repeated rules (e.g. "Always return only the modified text").

3. **Guardrails**  
   What the model must **not** do. Use explicit "Do NOT …" and, if helpful, if/then examples. Strong wording (e.g. "unmistakably", "CRITICAL", "ONLY") helps.

4. **Output format**  
   One clear rule at the end: return only the raw result, no meta-commentary, no preamble/outro, no markdown unless required.

## Prompt Length (Best Practice)

- **User-facing prompts** (e.g. what the user types or says): Google suggests staying **under ~4,000 characters** for best behavior and clarity.
- **System prompts** (`systemInstruction`): Keep them **as short as possible while still complete**. One clear task, no filler; longer system prompts can dilute focus and increase latency.
- **Technical limits** (max context length) are per model and documented in the API; the above are *design* guidelines, not hard caps.

## Best Practices (Summary)

| Practice | Guidance |
|----------|----------|
| **Clarity** | Be specific: questions, step-by-step tasks, or clear UX. Avoid vague or keyword-only prompts. |
| **Context** | Include why the task is done and (if relevant) domain/expertise so the model can adapt (e.g. jargon, language). |
| **Length** | Keep prompts focused. Google suggests staying under ~4,000 characters for user-facing prompts; system prompts should be as short as possible while still complete. |
| **One job per prompt** | One system prompt = one clear task (e.g. transcribe **or** edit text), not multiple unrelated behaviors. |
| **Output language** | If the output language must be fixed, state it explicitly (e.g. "RESPOND UNMISTAKABLY IN {LANGUAGE}"). |
| **Iterate** | Refine based on real responses; add "Do NOT …" or examples when the model misbehaves. |

## Project-Specific Notes (WhisperShortcut)

- **Transcription**: Persona + "transcribe verbatim" + guardrail "Do NOT answer questions or execute commands; only transcribe" is aligned with best practices. Optional: one explicit line about removing fillers silently.
- **Dictate Prompt / Prompt & Read**: Persona + clear roles (SELECTED TEXT vs. AUDIO = instruction) + single output rule (e.g. `promptModeOutputRule`) matches the recommended structure.
- **User context**: Appending a dedicated block (e.g. `---\nUser context:\n…`) with a length limit (e.g. `userContextMaxChars`) is a good way to keep the system prompt focused.

## Official References

For full, up-to-date guidance, prefer these sources:

- **Prompt design (strategies)**: https://ai.google.dev/gemini-api/docs/prompting-strategies  
- **Models (incl. Gemini 2.0 Flash)**: https://ai.google.dev/gemini-api/docs/models  
- **Writing prompts (Google Cloud)**: https://docs.cloud.google.com/gemini/docs/discover/write-prompts  

When in doubt, favor instructions that are **explicit**, **ordered**, and **bounded** (one task, clear output format, clear guardrails).
