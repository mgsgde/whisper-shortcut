#!/bin/bash

# Monthly meta-review of the self-improvement loops themselves.
#
# Runs the review-agent-loops skill headlessly: measures each loop's proposal funnel and
# hit rate from the ledgers, checks the loops actually fired (a loop that silently stops
# looks exactly like a quiet month), sweeps current best practices for autonomous agent
# loops, and exchanges lessons with sabaki.dance's loop setup (~/sabaki.dance.v3,
# read-only). Proposals go to plans/loop-ledger.md; the digest is mailed.
#
# Report-only, rung 0 (plans/agent-loops.md) — and doubly so here: this loop judges the
# machinery, so it must never edit the machinery unattended. It may only ever propose, and
# only ever in the tightening direction.
#
# Installed via ~/Library/LaunchAgents/com.whispershortcut.agent-loops.plist
# (6th of each month, 10:17 — after the month's first usage-review and growth-review, so
# there is fresh loop output to grade).

# Usage: agent-loops-job.sh [--dry-run] [--force]
#   --dry-run   check the plumbing, skip the Claude pass
#   --force     ignore the 7-day duplicate-firing gate
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# --- Subscription-only guard ---------------------------------------------------------------
# The Claude CLI bills per token when ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN) is set, and
# falls back to the Max subscription when it is not. Absence was true when this was written but
# nothing kept it true — a key exported in a shell profile would have flipped every scheduled job
# to paid without a word. So the keys are dropped here rather than trusted to be missing.
# Deliberate policy: this machinery runs on the subscription or it does not run.
for _v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  if [ -n "$(eval "echo \${$_v:-}")" ]; then
    echo "NOTE: unsetting $_v for this run — scheduled jobs run on the subscription, never per-token."
    unset "$_v"
  fi
done


# Opus, same reasoning as model-audit-job.sh: subscription auth means this costs rate-limit
# capacity, not dollars, and grading the graders is pure judgement work.
LOOPS_MODEL="${LOOPS_MODEL:-claude-opus-5}"
LOOPS_EFFORT="${LOOPS_EFFORT:-high}"
LOOPS_BUDGET_USD="${LOOPS_BUDGET_USD:-10}"
LOOPS_TIMEOUT_SECS="${LOOPS_TIMEOUT_SECS:-3600}"

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

STAMP="$(date +%Y-%m-%d)"
REVIEW_DIR="$REPO/plans/loop-reviews"
DIGEST="$REVIEW_DIR/$STAMP-review.md"
LEDGER="$REPO/plans/loop-ledger.md"
SKILL="$REPO/.agents/skills/review-agent-loops/SKILL.md"
SABAKI="$HOME/sabaki.dance.v3"
mkdir -p "$REVIEW_DIR"

AUDIT_MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

notify() {
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" \
    >/dev/null 2>&1 || true
}

report_out() {
  local subject="$1" body="$2"; shift 2
  if python3 "$REPO/scripts/send-report-mail.py" --to "$AUDIT_MAIL_TO" \
       --subject "$subject" --body-file "$body" "$@"; then
    return 0
  fi
  echo "WARN: could not send mail — falling back to a local notification"
  notify "$subject" "Email failed. Digest: $body"
}

fail_out() {
  local verdict="$1"; shift
  echo "VERDICT: $verdict"
  local note; note="$(mktemp -t wsloopsfail)"
  { echo "VERDICT: $verdict"; echo; for line in "$@"; do echo "$line"; done; } > "$note"
  report_out "WhisperShortcut agent-loops review FAILED ($STAMP)" "$note" \
    --verdict needs-fix --verdict-detail "$verdict This run produced no proposals, so nothing \
reached the implementer queue. Nothing retries it — the next scheduled run is a month away \
unless you re-run it by hand (command below)."
  notify "WhisperShortcut agent-loops review FAILED" "$verdict"
  rm -f "$note"
  exit 1
}

echo "=== Agent-loops review started: $(date '+%Y-%m-%d %H:%M:%S') ==="

# ------------------------------------------------------------------ 0. cadence gate
# Monthly via launchd; the gate stops a duplicate firing (wake catch-up) from burning a run.
# A wake catch-up fires within hours of the missed slot, so 7 days is all the gate needs. It used
# to be 20, and that skipped the 2026-09-06 run outright: the previous digest was a manual run on
# 2026-08-20, 17 days earlier, so the "duplicate" guard swallowed a whole scheduled month and the
# next honest run moved to October — the same class of bug as sabaki's weekly loops skipping
# every Saturday that fell on the 29th–31st (their fix 2026-09-01). A gate that can cancel a
# scheduled run must be narrower than the schedule.
# The date is read from the file NAME, not its mtime: a `git checkout` or an edit to an old
# digest resets mtime and would re-arm the gate against a run that never happened.
if [ "$FORCE" -eq 0 ]; then
  NEWEST="$(ls "$REVIEW_DIR" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-review\.md$' | sort | tail -1)"
  if [ -n "$NEWEST" ]; then
    NEWEST_EPOCH="$(date -j -f '%Y-%m-%d' "${NEWEST%-review.md}" '+%s' 2>/dev/null || echo 0)"
    AGE_DAYS=$(( ( $(date +%s) - NEWEST_EPOCH ) / 86400 ))
    if [ "$AGE_DAYS" -lt 7 ]; then
      echo "Newest digest $NEWEST is $AGE_DAYS days old — duplicate firing, exiting quietly."
      exit 0
    fi
  fi
fi

SABAKI_NOTE="available at $SABAKI"
[ -d "$SABAKI/docs" ] || SABAKI_NOTE="NOT available — skip the cross-repo section and say so in the digest"
echo "Sabaki repo: $SABAKI_NOTE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== --dry-run: skipping the Claude pass. Done: $(date '+%H:%M:%S') ==="
  exit 0
fi

# ------------------------------------------------------------------ 1. review
PROMPT_FILE="$(mktemp -t wsloops)"
trap 'rm -f "$PROMPT_FILE" "${KILLED_MARKER:-}"' EXIT
cat > "$PROMPT_FILE" <<EOF
You are the scheduled meta-review job for WhisperShortcut's self-improvement loops
(repo: $REPO).

Read $SKILL and follow it exactly. Notes specific to this scheduled run:

- Sabaki repo for the cross-repo section: $SABAKI_NOTE.
- Write the digest FIRST, to: $DIGEST
  Its first line must be exactly:  VERDICT: <one sentence, max 120 chars>
  The job reads that line back for the mail subject and treats a missing digest as a
  failed run.
- Then add at most 3 rows to $LEDGER and one row to its Run log, per that file's rules.

Hard constraints (rung 0, report-only — see plans/agent-loops.md):
- Do NOT edit any skill, script, plist, or config — not even the loops' own files. Propose only.
- Never write anything under $SABAKI — the export block in the digest is the only channel.
- Do NOT commit or push anything.
- Scheduled report: write in English.
EOF

# The report above is for the human. This block asks the same run to ALSO leave a
# machine-readable proposal file for the implementer's groomer, so a finding no longer stops at
# a ledger row nobody flags. The schema lives in one place, not four:
# scripts/implementer/proposal-prompt.sh. Appending is best-effort — a loop whose report is
# written must not fail because the sidecar prompt could not be generated.
# The path is fixed here rather than left to the helper's clock, because this run's mail has to
# say whether anything reached the implementer queue — and "proposed nothing" must not look like
# "wrote its file under a name nobody counted".
# The rules that bind a run with no user at the keyboard — escalation test, the null-verdict rule
# for this kind of loop, the mandatory deletion candidate. Shared with the other jobs through one
# file so the four prompts cannot drift apart (scripts/loop-prompt.sh; the reasoning is in
# plans/agent-loops.md, "Shared conventions"). Best-effort like the proposal block below.
bash "$REPO/scripts/loop-prompt.sh" null-ok >>"$PROMPT_FILE" \
  || echo "WARN: could not append the shared loop rules — this run reports without them."

IMPLEMENTER_PROPOSAL_FILE="$(bash "$REPO/scripts/implementer/proposal-prompt.sh" agent-loops --path-only)"
export IMPLEMENTER_PROPOSAL_FILE
bash "$REPO/scripts/implementer/proposal-prompt.sh" agent-loops >>"$PROMPT_FILE" \
  || echo "WARN: could not append the implementer-proposal block — this run reports only."


echo "Review pass: model=$LOOPS_MODEL effort=$LOOPS_EFFORT budget=\$$LOOPS_BUDGET_USD timeout=${LOOPS_TIMEOUT_SECS}s"

KILLED_MARKER="$(mktemp -t wsloopskill)"
rm -f "$KILLED_MARKER"

claude -p --dangerously-skip-permissions \
  --model "$LOOPS_MODEL" --effort "$LOOPS_EFFORT" --max-budget-usd "$LOOPS_BUDGET_USD" \
  "$(cat "$PROMPT_FILE")" 2>&1 &
CLAUDE_PID=$!

( sleep "$LOOPS_TIMEOUT_SECS"
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    : > "$KILLED_MARKER"
    kill -TERM "$CLAUDE_PID" 2>/dev/null
    sleep 10
    kill -KILL "$CLAUDE_PID" 2>/dev/null
  fi ) &
WATCHDOG_PID=$!

wait "$CLAUDE_PID"
STATUS=$?
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

if [ $STATUS -ne 0 ] || [ ! -f "$DIGEST" ]; then
  if [ -f "$KILLED_MARKER" ]; then
    WHY="agent-loops review TIMED OUT — killed after ${LOOPS_TIMEOUT_SECS}s without finishing."
  elif [ $STATUS -ne 0 ]; then
    WHY="agent-loops review FAILED — claude exited with status $STATUS."
  else
    WHY="agent-loops review INCOMPLETE — the pass wrote no digest."
  fi
  rm -f "$KILLED_MARKER"
  fail_out "$WHY" \
    "Log: $REPO/build/logs/agent-loops.log" \
    "Re-run manually with: bash scripts/agent-loops-job.sh --force"
fi

ln -sf "$(basename "$DIGEST")" "$REVIEW_DIR/LATEST.md"

VERDICT="$(head -1 "$DIGEST" | sed 's/^VERDICT:[[:space:]]*//')"
[ -n "$VERDICT" ] || VERDICT="Digest written (no verdict line found)"
# The subject is the job and the date, not the finding. The finding used to lead it and ran to 120
# characters, which pushed the one thing a phone notification has to show — whether this needs you —
# past where every mail client truncates. It still leads the mail itself ("In one line:"), and the
# notification below still speaks it.
report_out "WhisperShortcut agent-loops review ($STAMP)" "$DIGEST" \
  --verdict proposals --proposals-file "$IMPLEMENTER_PROPOSAL_FILE" \
  --title "Agent-loops review $STAMP" \
  --meta "Job=agent-loops (monthly)" --meta "Digest=$DIGEST"
notify "WhisperShortcut agent-loops review" "$VERDICT"
echo "VERDICT: $VERDICT"
echo "Digest: $DIGEST"
echo "=== Agent-loops review finished: $(date '+%Y-%m-%d %H:%M:%S') ==="
