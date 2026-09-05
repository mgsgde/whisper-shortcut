#!/bin/bash

# Biweekly growth/strategy review for WhisperShortcut.
#
# Runs the review-growth skill headlessly: pulls real business metrics (App Store Connect
# via asc, GitHub via gh, git effort, a light competitor pass), names the ONE bottleneck
# toward paying customers, grades the previous run's recommendation, and appends an entry
# to ../business/growth-ledger.md. Then it says so, by mail with a macOS notification fallback.
#
# It runs locally and not as a cloud routine because its inputs only exist here: asc and gh
# authenticate through this Mac's Keychain, and the usage digests it cross-reads are mined
# from the local app container. Same reasoning as usage-review-job.sh.
#
# It deliberately does NOT change code, App Store metadata, or anything else — report-only,
# rung 0 of the autonomy ladder (plans/agent-loops.md). The ledger is the deliverable.
#
# Installed via ~/Library/LaunchAgents/com.whispershortcut.growth-review.plist
# (Saturdays 09:07; the 11-day gate below makes the effective cadence biweekly, and a
# missed Saturday — Mac asleep — is caught by the next one instead of waiting two weeks).

# Usage: growth-review-job.sh [--dry-run] [--force]
#   --dry-run   check the plumbing (auth, gates), skip the Claude pass
#   --force     ignore the 11-day cadence gate
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


# Cost controls for the unattended pass. Opus, same reasoning as model-audit-job.sh: the
# CLI authenticates against a Claude Max subscription, so this consumes rate-limit
# capacity, not dollars, and the whole value of a strategy verdict is judgement quality.
# --max-budget-usd stays as the backstop for a future API-key world.
GROWTH_MODEL="${GROWTH_MODEL:-claude-opus-5}"
GROWTH_EFFORT="${GROWTH_EFFORT:-high}"
GROWTH_BUDGET_USD="${GROWTH_BUDGET_USD:-10}"
GROWTH_TIMEOUT_SECS="${GROWTH_TIMEOUT_SECS:-3600}"

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
# Business data lives in the PRIVATE parent repo, never in this public one.
# See plans/README.md "What must never be committed here".
BUSINESS_DIR="${WS_BUSINESS_DIR:-$REPO/../business}"
REVIEW_DIR="$BUSINESS_DIR/growth-reviews"
DIGEST="$REVIEW_DIR/$STAMP-review.md"
LEDGER="$BUSINESS_DIR/growth-ledger.md"
SKILL="$REPO/.cursor/skills/review-growth/SKILL.md"
if [ ! -d "$BUSINESS_DIR" ]; then
  echo "ERROR: no private business dir at $BUSINESS_DIR — this job writes revenue data and"
  echo "must never write it into the public app repo. Aborting."
  exit 1
fi
mkdir -p "$REVIEW_DIR"

AUDIT_MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

notify() {
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" \
    >/dev/null 2>&1 || true
}

report_out() {
  local subject="$1" body="$2"
  if python3 "$REPO/scripts/send-report-mail.py" --to "$AUDIT_MAIL_TO" \
       --subject "$subject" --body-file "$body"; then
    return 0
  fi
  echo "WARN: could not send mail — falling back to a local notification"
  notify "$subject" "Email failed. Digest: $body"
}

fail_out() {
  local verdict="$1"; shift
  echo "VERDICT: $verdict"
  local note; note="$(mktemp -t wsgrowthfail)"
  { echo "VERDICT: $verdict"; echo; for line in "$@"; do echo "$line"; done; } > "$note"
  report_out "WhisperShortcut growth review FAILED ($STAMP)" "$note"
  notify "WhisperShortcut growth review FAILED" "$verdict"
  rm -f "$note"
  exit 1
}

echo "=== Growth review started: $(date '+%Y-%m-%d %H:%M:%S') ==="

# ------------------------------------------------------------------ 0. cadence gate
# launchd fires weekly (so a slept-through Saturday costs one week, not two); this gate is
# what makes the effective cadence biweekly.
if [ "$FORCE" -eq 0 ]; then
  RECENT="$(find "$REVIEW_DIR" -name '*-review.md' -mtime -11 2>/dev/null | head -1)"
  if [ -n "$RECENT" ]; then
    echo "Newest digest is younger than 11 days ($RECENT) — biweekly cadence, exiting quietly."
    exit 0
  fi
fi

# ------------------------------------------------------------------ 1. can we measure?
# A growth review without business numbers is an opinion column. If neither data source
# authenticates, fail loudly — a silent skip looks like a healthy loop that found nothing.
ASC_OK=1
asc apps list >/dev/null 2>&1 || ASC_OK=0
GH_OK=1
gh auth status >/dev/null 2>&1 || GH_OK=0
echo "Data sources: asc=$( [ $ASC_OK -eq 1 ] && echo OK || echo UNAVAILABLE ), gh=$( [ $GH_OK -eq 1 ] && echo OK || echo UNAVAILABLE )"

if [ "$ASC_OK" -eq 0 ] && [ "$GH_OK" -eq 0 ]; then
  fail_out "growth review BLOCKED — neither asc nor gh can authenticate; no numbers to review." \
    "Check: 'asc doctor' and 'gh auth status' in a terminal (Keychain may be locked)." \
    "Then re-run with: bash scripts/growth-review-job.sh --force"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== --dry-run: skipping the Claude pass. Done: $(date '+%H:%M:%S') ==="
  exit 0
fi

# ------------------------------------------------------------------ 2. review
# Prompt via temp file — macOS bash 3.2 mis-parses apostrophes in nested heredocs.
PROMPT_FILE="$(mktemp -t wsgrowth)"
trap 'rm -f "$PROMPT_FILE" "${KILLED_MARKER:-}"' EXIT
cat > "$PROMPT_FILE" <<EOF
You are the scheduled growth-review job for WhisperShortcut (repo: $REPO).

Read $SKILL and follow it exactly — it defines the goal, the evidence to gather, and the
verdict format. Notes specific to this scheduled run:

- Unavailable data sources this run: $( [ $ASC_OK -eq 1 ] && echo "none known" || echo "asc (App Store Connect) failed its auth probe — mark those metrics unmeasured, do not retry endlessly" )$( [ $GH_OK -eq 0 ] && echo "; gh failed its auth probe — mark GitHub metrics unmeasured" ).
- Write the digest FIRST, to: $DIGEST
  Its first line must be exactly:  VERDICT: <one sentence, max 120 chars, naming the bottleneck>
  The job reads that line back for the mail subject, and treats a missing digest as a
  failed run — so write it before deep analysis polish, then refine.
- Then append the dated entry to $LEDGER and add a row to its Run log, per the rules at
  the top of that file.

Hard constraints (rung 0, report-only — see plans/agent-loops.md):
- Do NOT change any code, prompts, defaults, settings, or App Store Connect state
  (asc strictly read-only).
- Do NOT commit or push anything.
- Scheduled report: write in English.
EOF

# The report above is for the human. This block asks the same run to ALSO leave a
# machine-readable proposal file for the implementer's groomer, so a finding no longer stops at
# a ledger row nobody flags. The schema lives in one place, not four:
# scripts/implementer/proposal-prompt.sh. Appending is best-effort — a loop whose report is
# written must not fail because the sidecar prompt could not be generated.
bash "$REPO/scripts/implementer/proposal-prompt.sh" growth-review >>"$PROMPT_FILE" \
  || echo "WARN: could not append the implementer-proposal block — this run reports only."


echo "Review pass: model=$GROWTH_MODEL effort=$GROWTH_EFFORT budget=\$$GROWTH_BUDGET_USD timeout=${GROWTH_TIMEOUT_SECS}s"

# Budget caps what a stuck run costs, not how long it runs — kill it ourselves (macOS has
# no `timeout`). Sentinel distinguishes "we killed it" from "it died".
KILLED_MARKER="$(mktemp -t wsgrowthkill)"
rm -f "$KILLED_MARKER"

claude -p --dangerously-skip-permissions \
  --model "$GROWTH_MODEL" --effort "$GROWTH_EFFORT" --max-budget-usd "$GROWTH_BUDGET_USD" \
  "$(cat "$PROMPT_FILE")" 2>&1 &
CLAUDE_PID=$!

( sleep "$GROWTH_TIMEOUT_SECS"
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
    WHY="growth review TIMED OUT — killed after ${GROWTH_TIMEOUT_SECS}s without finishing."
  elif [ $STATUS -ne 0 ]; then
    WHY="growth review FAILED — claude exited with status $STATUS."
  else
    WHY="growth review INCOMPLETE — the pass wrote no digest."
  fi
  rm -f "$KILLED_MARKER"
  fail_out "$WHY" \
    "Log: $REPO/build/logs/growth-review.log" \
    "Re-run manually with: bash scripts/growth-review-job.sh --force"
fi

ln -sf "$(basename "$DIGEST")" "$REVIEW_DIR/LATEST.md"

VERDICT="$(head -1 "$DIGEST" | sed 's/^VERDICT:[[:space:]]*//')"
[ -n "$VERDICT" ] || VERDICT="Digest written (no verdict line found)"
report_out "WhisperShortcut growth review — $VERDICT" "$DIGEST"
notify "WhisperShortcut growth review" "$VERDICT"
echo "VERDICT: $VERDICT"
echo "Digest: $DIGEST"
echo "=== Growth review finished: $(date '+%Y-%m-%d %H:%M:%S') ==="
