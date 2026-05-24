---
name: validate-audio-verification
description: Validate end-to-end that Smart Improvement audio verification is actually working — audio is captured for dictation, attached only when the asymmetry rule passes, used by the dictation and Whisper Glossary focuses, and cleaned up afterwards.
---

# Validate Audio Verification

User-facing entry point for the Smart Improvement audio-verification inspection procedure. The canonical playbook lives in `.cursor/skills/validate-audio-verification/SKILL.md` — follow it end-to-end.

## When to invoke

- The user asks "is audio verification working?" or "did Smart Improvement use audio this run?".
- Immediately after implementing or modifying anything in the Smart Improvement audio-verification path (`ContextDerivation.swift`, dictation capture, asymmetry rule, cleanup).
- When investigating why a glossary or dictation suggestion was — or was not — produced.

## How to run

Walk the skill's five validation questions in order:

1. Was audio captured for recent dictations? (`bash scripts/logs.sh -t 30m -f 'AUDIO-VERIFY: capture'`)
2. Was the asymmetry rule evaluated, and what did it decide?
3. Was the captured audio actually attached to the Smart Improvement request?
4. Was it received by the dictation / Whisper Glossary focuses?
5. Was the audio cleaned up afterwards?

Each question maps to one specific log filter or on-disk check — see the skill for the exact commands.

## Constraints

- **Confirm preconditions first** (usage logging on, recent dictation since last Smart Improvement run, known dictation backend + Smart Improvement model). If any precondition is missing, validation is inconclusive — say so rather than reporting "broken".
- **Read-only.** Do not modify code from this command. If the audit surfaces a real bug, switch to **debugging-workflow** (skill) before instrumenting.

## Related

- **`validate-audio-verification` skill** — the canonical playbook with the five questions, log filters, expected outcomes, and the `AUDIO-VERIFY:` logging contract.
- **`view-logs-via-bash` skill** — for the underlying `bash scripts/logs.sh` invocations.
- **`debugging-workflow` skill** — when you need to add new `DebugLogger` instrumentation to track down a regression the audit found.
