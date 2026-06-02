---
name: review-llm-state-of-the-art
description: Review whether this app's LLM architecture is still state of the art by comparing current code paths to live OpenAI/Gemini/xAI best practices, then return a prioritized modernization roadmap.
---

# Review LLM State Of The Art

Assess whether this app's LLM stack and interaction patterns are still modern by combining:

1. **Codebase reality** (how WhisperShortcut currently works), and
2. **Live provider guidance** (OpenAI, Gemini, xAI current capabilities and best practices).

Follow the canonical procedure in `.cursor/skills/review-llm-state-of-the-art/SKILL.md`.

## What this command should deliver

- A clear verdict on what is already strong vs what is outdated.
- A prioritized `Now / Next / Later` roadmap with effort/risk.
- One concrete "first slice" implementation recommendation.

## Scope

Default scope includes:

- Chat/provider abstraction and tool loop
- Prompting and structured output reliability
- Dictation/transcription and TTS architecture
- Model currency and migration hygiene
- Operational quality (logging, failure handling, maintainability)

## Constraints

- Suggestions only by default (no file edits) unless the user explicitly says "apply" / "fix".
- Major claims must be grounded in live docs, not memory.
- Keep recommendations practical and high impact; avoid fashion-driven churn.

## Related commands

- `/audit-llm-models` — deep model-lineup and provider-coverage audit.
- `/analyze-user-interactions` — usage-log-driven failure patterns from real interactions.
- `/review-code` — static code review for regressions and simplification opportunities.

## Example invocation

- `/review-llm-state-of-the-art`
