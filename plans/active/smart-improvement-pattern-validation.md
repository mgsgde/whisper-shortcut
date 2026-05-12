# Smart Improvement Prompt Evidence Requirements

## Goal

Ensure Smart Improvement prompts clearly instruct Gemini to suggest system prompt or glossary changes only when the supporting interaction logs show recurring, generic, durable patterns. This plan intentionally keeps the enforcement in the Smart Improvement system prompt, not in a separate programmatic validator.

## Context

- `WhisperShortcut/ContextDerivation.swift` loads sampled interaction logs, asks Gemini to generate one focused suggestion, writes the suggestion file, and writes an optional rationale file.
- Recent prompt changes added a recurring-pattern requirement in `commonFooter` and all four focus prompts: dictation, Whisper glossary, Dictate Prompt, and Chat.
- The desired behavior is prompt-level: Gemini must ignore one-off words, isolated topics, single unusual instructions, and concrete temporary details when generating Smart Improvement suggestions.
- The riskiest outputs are persistent prompt/glossary suggestions based on one-off words, isolated topics, or single unusual instructions.
- Smart Improvement suggestions should abstract from repeated examples into reusable behavior rules instead of copying concrete tasks, project names, people, tools, dates, or transient plans into prompts.
- Keep the implementation local to the Smart Improvement prompts. Use `DebugLogger`, not `print`/`NSLog`/`os_log`, if future logging changes are made.

## Non-Goals

- Do not add programmatic evidence validation, rationale parsing, semantic clustering, or a second LLM review pass.
- Do not auto-apply any Smart Improvement output. This plan only governs whether suggestion files are written for review.
- Do not change the interaction log schema.
- Do not make the threshold user-configurable initially.

## Implementation Plan

1. Strengthen the shared Smart Improvement footer in `ContextDerivation.swift`.
   - Define a recurring pattern as evidence from at least 3 distinct primary interactions.
   - State that single occurrences, one-off quirks, isolated topics, and isolated words must be ignored.
   - State that secondary/background context cannot justify a change by itself.
   - State that suggested prompts must stay generic, durable, and reusable.
   - Exclude concrete tasks, temporary projects, personal facts, names, dates, current plans, specific entities, and transient context.

2. Require structured rationale evidence in the system prompt.
   - For each kept change, require:
     - `Change: ...`
     - `Evidence count: N distinct primary interactions`
     - `Evidence summary: ...`
     - `Decision: KEEP`
   - Instruct Gemini to drop any candidate with `Evidence count` below 3.
   - Instruct Gemini to output only `NO_CHANGE` if no candidate reaches that threshold.

3. Require abstraction and prompt bloat control.
   - Repeated concrete examples may only justify a broader behavior rule.
   - Gemini must not copy example content into the suggested prompt.
   - Prefer `NO_CHANGE` unless a new rule replaces, merges, shortens, or materially improves an existing generic rule.
   - Keep suggested prompts equal in length or shorter unless a broadly useful recurring behavior clearly requires a new rule.

4. Align focus-specific prompts with primary-evidence behavior.
   - Dictation and Prompt Mode should say primary interactions are the evidence source.
   - Secondary data may help wording or provide background, but must not justify a new prompt rule.
   - If primary data does not show recurring patterns, Gemini should output `NO_CHANGE`.

5. Do not change `writeOutputFile` behavior for this plan.
   - Continue using the existing marker and `NO_CHANGE` parsing.
   - Do not add rationale parsing or rejection logic in code.

## Acceptance Criteria

- The shared Smart Improvement system prompt defines a recurring pattern as at least 3 distinct primary interactions.
- The shared Smart Improvement system prompt requires suggestions to remain generic, durable, reusable, and abstracted from concrete examples.
- The system prompt explicitly forbids adding concrete tasks, temporary projects, names, dates, current plans, specific entities, or transient context to suggested prompts.
- The rationale format requires explicit `Evidence count` and `Decision: KEEP` for every proposed change.
- The system prompt tells Gemini to drop candidates below the threshold and use `NO_CHANGE` when no candidate qualifies.
- The system prompt prefers `NO_CHANGE` over prompt bloat or niche guidance.
- Secondary context is described as background only, not evidence for new rules.
- Existing marker parsing and `NO_CHANGE` behavior continue to work.

## Verification

- Rebuild with `bash scripts/rebuild-and-restart.sh` directly, without piping or output filters.
- Manually run Smart Improvement and inspect the generated rationale file.
- Confirm every retained change uses the structured evidence format.
- Confirm the rationale does not cite isolated words, one-off topics, or secondary-only context as sufficient evidence.
- Confirm suggested prompts do not include concrete tasks, temporary project details, names, dates, current plans, specific entities, or copied example content.
- User runs any Xcode tests manually if needed.
