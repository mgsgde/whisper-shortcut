---
name: review-llm-state-of-the-art
description: Review the app's LLM architecture and interaction design against current provider best practices (OpenAI, Gemini, xAI), then deliver a prioritized "keep / change / later" roadmap with concrete implementation slices.
---

# Review LLM State Of The Art

Use this when the user asks whether the app's LLM setup is still "state of the art", "modern", "up to date", or "how people would build this today".

Goal: produce a high-signal architecture review grounded in the current codebase **and** live provider docs, not generic trend commentary.

## Scope and posture

- This is a **review command** first: identify strengths, gaps, and high-impact upgrades.
- Default output is **suggestions only**. Do not edit files unless the user says "apply", "fix", or "do it".
- Focus on meaningful product/architecture outcomes, not style nitpicks.

## Workflow

1. **Map current implementation (repo-first)**
   - Read the primary LLM paths:
     - `WhisperShortcut/LLMChatProvider.swift`
     - `WhisperShortcut/GeminiChatProvider.swift`
     - `WhisperShortcut/OpenAIChatProvider.swift`
     - `WhisperShortcut/GrokChatProvider.swift`
     - `WhisperShortcut/SpeechService.swift`
     - `WhisperShortcut/AppConstants.swift`
     - `WhisperShortcut/ChatView.swift`
     - `WhisperShortcut/Settings/Shared/SettingsConfiguration.swift`
     - `WhisperShortcut/TranscriptionModels.swift`
   - Capture what the app does today: provider abstraction, streaming behavior, tool-use loop, STT/TTS path, structured outputs vs prompt parsing, model defaults, migrations, and guardrails.

2. **Refresh live docs before judging modernity (mandatory)**
   - Read `.cursor/skills/llm-model-docs/SKILL.md` and follow its current-doc workflow.
   - Verify key claims against live docs/forums (OpenAI, Gemini, xAI), especially:
     - structured output/schema enforcement support,
     - chat/tool-calling patterns,
     - speech/transcription/realtime capabilities,
     - model lifecycle/deprecations and GA vs preview status.
   - If docs are JS-blocked or unavailable, use `WebSearch` and mark confidence accordingly.

3. **Evaluate with a fixed rubric**
   - Score each area as `strong`, `acceptable`, or `gap`:
     - **Provider architecture** (abstraction quality, portability, fallback behavior)
     - **Reliability for machine-readable outputs** (native schema enforcement vs marker/regex parsing)
     - **Agent/tool loop quality** (round limits, parallel calls, termination safety)
     - **Speech UX architecture** (batch vs realtime STT tradeoffs, latency implications)
     - **Prompt/system design quality** (instruction clarity, anti-leak handling, brittleness)
     - **Observability and operability** (logging quality, failure diagnostics, migration safety)
     - **Model currency and coverage** (defaults, retired slugs, per-provider feature reach)

4. **Prioritize recommendations by ROI**
   - For each gap, provide:
     - why it matters now,
     - user impact (quality/latency/reliability/cost),
     - implementation effort (`S`, `M`, `L`),
     - risk level (`low`, `medium`, `high`),
     - recommended rollout order.
   - Explicitly separate:
     - **Now** (high ROI, low/medium effort),
     - **Next** (valuable but larger),
     - **Later** (optional strategic bets).

5. **Define first implementation slice**
   - Propose one concrete first step that is tightly scoped and testable (for example, replacing fragile parsed outputs in one internal flow with schema-enforced structured outputs).

## Output format

### Verdict
- 2-4 bullets: what is already modern and where the real gaps are.

### Strengths worth keeping
- Concrete architecture decisions that are already state-of-the-art enough.

### Gaps vs current best practice
- `severity` + `area` + `evidence` + short impact statement.
- Tag each as `[diff]` (recently touched) or `[area]` (existing architecture gap).

### Recommended roadmap
- **Now** / **Next** / **Later** with effort + risk.

### First slice to implement
- Exact files likely to change and why this is the best first step.

### Open questions
- Decisions requiring user/product input (latency vs complexity, provider priorities, cost constraints).

## Constraints

- Do not claim "state of the art" from memory; back major claims with live docs.
- Avoid trendy but low-impact suggestions. Prioritize reliability and user-visible gains.
- Keep recommendations aligned with project rules (`AppState`, `DebugLogger`, KISS, English UI text).

## When the user follows up with "apply"

1. Implement the selected `Now` recommendation(s).
2. Keep scope tight; do not batch unrelated refactors.
3. Rebuild and restart: `bash scripts/rebuild-and-restart.sh`.
4. Do not commit unless explicitly requested.
