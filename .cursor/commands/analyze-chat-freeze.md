---
name: analyze-chat-freeze
description: Triage a WhisperShortcut chat-window main-thread freeze from the on-disk hang captures and logs — classify real vs. false-positive, localize the wedge, and continue the investigation. Follows the procedure in .cursor/skills/analyze-chat-freeze/SKILL.md.
---

# Analyze Chat Freeze

Triage a chat-window main-thread freeze (beachball, ~100% CPU, logs go silent) from the watchdog's `hang-*.txt` captures and the surrounding app logs — decide whether it is a real product hang or a known false positive, localize where the main thread wedged, and either confirm the shipped fix held or continue root-causing a new variant.

**Read `.cursor/skills/analyze-chat-freeze/SKILL.md` and follow its procedure end-to-end.** The skill is the source of truth for the capture/log locations, the real-vs-false-positive triage table, the two known real-hang stack signatures, the shipped fix and its invariants, and the log markers that prove the fix held. This command only adds the invocation-time scope flags below — don't restate the skill's content.

## Scope resolution

Resolve scope in this order, then **print it first** (which capture(s), their breadcrumbs, app version) so the user can redirect before you dig in:

1. **Explicit override** — honor any flag the user passes:
   - `--file <hang-….txt>` — analyze this specific capture only.
   - `--since <range>` — only captures newer than this (default: the most recent capture).
2. **Default** — the newest `hang-*.txt` in the Logs directory, cross-referenced against that day's `app_YYYY-MM-DD.log`.

## Primary sources (see skill for exact paths)

- Hang captures + daily logs: `~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Logs/WhisperShortcut/`
- Live log tail: `bash scripts/logs.sh -f 'WATCHDOG|CHAT-SEND|CHAT-LIST' -t 30m`
- Background: `plans/active/chat-freeze-investigation.md` (full history + the shipped Resolution).

## When the user follows up with "fix" / "apply"

Only if the triage finds a **new real** wedge (not the resolved one). Propose the smallest change consistent with the shipped architecture (streaming bubble stays outside the `LazyVStack`), then rebuild via `bash scripts/rebuild-and-restart.sh` before reporting. Do not commit unless explicitly asked.

## Related commands

- **`/review-code`** — static review of the chat code instead of a capture-driven diagnosis.
- **`/analyze-user-interactions`** — usage-pattern mining when the symptom is behavioral, not a hang.

(Skill-level cross-links — debugging-workflow, view-logs-via-bash — are listed in the skill itself.)

## Example invocations

- `analyze-chat-freeze` — newest capture, default scope.
- `analyze-chat-freeze --file hang-20260703-093924.txt` — a specific capture.
- `analyze-chat-freeze --since "2 days"` — every capture in the last two days.
