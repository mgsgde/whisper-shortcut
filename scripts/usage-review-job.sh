#!/bin/bash

# Weekly usage-review job for WhisperShortcut.
#
# Reads a week of real usage off this Mac — the interaction logs and the outcome-signal stream in
# the app's container — and turns recurring failures into at most three concrete proposals in
# plans/improvement-ledger.md. Then it says so, by mail with a macOS notification as fallback.
#
# It runs locally and not as a cloud routine for one unavoidable reason: the data only exists here.
# The JSONL lives in the sandboxed container under ~/Library/Containers, is never committed, and
# never leaves the machine. A cloud agent with a git checkout of this repo would see an empty
# ledger and nothing to mine.
#
# It deliberately does NOT write plan files and does NOT change code. A weekly job that edits an
# app you use daily, unattended and unreviewed, is a liability; proposals are cheap to ignore and
# code changes are not. The ledger is the deliverable.
#
# The container data is copied into build/usage-review-staging/ before the Claude pass runs, and the
# pass reads only that copy — bash has the Full Disk Access grant, claude's sandboxed Bash tool does
# not, and a read it is not allowed to make hangs rather than failing. See section 1.
#
# Installed via ~/Library/LaunchAgents/com.whispershortcut.usage-review.plist (Mondays 08:47).
# Costs well under a dollar per run — no web research, one local reading pass.

# Usage: usage-review-job.sh [--dry-run] [--days N]
#   --dry-run   summarise what would be reviewed, skip the Claude pass (no ledger writes)
#   --days N    review window in days (default 7)
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Cost controls for the unattended pass, same reasoning as model-audit-job.sh: without these the
# job inherits ~/.claude/settings.json, which is tuned for interactive work. `--max-budget-usd` is
# a hard stop enforced by the CLI, so a runaway loop costs the cap and not a month's budget.
REVIEW_MODEL="${REVIEW_MODEL:-sonnet}"
REVIEW_EFFORT="${REVIEW_EFFORT:-high}"
REVIEW_BUDGET_USD="${REVIEW_BUDGET_USD:-3}"

DRY_RUN=0
DAYS=7
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --days) shift; DAYS="${1:-7}" ;;
    *) echo "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

# Overridable so the permission-denied path can be exercised against a fixture without waiting for
# a real TCC denial — that path is the one that must never fail silently, so it must be testable.
CONTEXT_DIR="${REVIEW_CONTEXT_DIR:-$HOME/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext}"
LEDGER="$REPO/plans/improvement-ledger.md"
# The review pass never reads CONTEXT_DIR itself — bash copies the window here first. See section 1.
STAGING="$REPO/build/usage-review-staging"
STAMP="$(date +%Y-%m-%d)"
# Digests quote real transcript fragments — private parent repo only, never the public app repo.
BUSINESS_DIR="${WS_BUSINESS_DIR:-$REPO/../business}"
REVIEW_DIR="$BUSINESS_DIR/usage-reviews"
DIGEST="$REVIEW_DIR/$STAMP-review.md"
if [ ! -d "$BUSINESS_DIR" ]; then
  echo "ERROR: no private business dir at $BUSINESS_DIR — usage digests quote real transcripts"
  echo "and must never land in the public app repo. Aborting."
  exit 1
fi
mkdir -p "$REVIEW_DIR"

# Reporting helpers are defined up here, not next to their first use, because the earliest thing
# that can go wrong (an unreadable container) has to be able to report loudly too.
AUDIT_MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

notify() {
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" \
    >/dev/null 2>&1 || true
}

# report_out <subject> <body-file> — mail it, notify locally if that fails. The Keychain is
# unreadable while the Mac is locked, which at 08:47 on a Monday is a normal condition.
report_out() {
  local subject="$1" body="$2"
  if python3 "$REPO/scripts/send-report-mail.py" --to "$AUDIT_MAIL_TO" \
       --subject "$subject" --body-file "$body"; then
    return 0
  fi
  echo "WARN: could not send mail — falling back to a local notification"
  notify "$subject" "Email failed. Digest: $body"
}

# fail_out <verdict line> <extra line …> — report a broken run and exit non-zero.
fail_out() {
  local verdict="$1"; shift
  echo "VERDICT: $verdict"   # also to the log — mail and notification can both be unavailable
  local note; note="$(mktemp -t wsreviewfail)"
  { echo "VERDICT: $verdict"; echo; for line in "$@"; do echo "$line"; done; } > "$note"
  report_out "WhisperShortcut usage review FAILED ($STAMP)" "$note"
  notify "WhisperShortcut usage review FAILED" "$verdict"
  rm -f "$note"
  exit 1
}

echo "=== Usage review started: $(date '+%Y-%m-%d %H:%M:%S') (window: ${DAYS}d) ==="

if [ ! -d "$CONTEXT_DIR" ]; then
  echo "ERROR: no UserContext directory at $CONTEXT_DIR — is 'Save usage data' off? Aborting."
  exit 1
fi

# ---------------------------------------------------------------- 0. can we actually read it?
# macOS TCC does not grant a launchd job the file access your Terminal has. When it denies this
# directory, `opendir` fails, the globs below expand to nothing, the count comes out zero, and the
# job exits reporting a quiet week — which is the exact failure this whole design is supposed to
# prevent.
#
# This is measured, not assumed. A throwaway LaunchAgent probing this directory on 2026-08-02
# reported `list: DENIED`, `read: DENIED`, `interaction files visible: 0` — and after granting
# /bin/bash Full Disk Access, `OK / OK / 15`, with `python3` and `wc` children inheriting the grant
# (which is what matters: claude and python3 do the actual reading, not bash).
#
# The grant is in place, so this probe should pass. It stays because a revoked grant would
# otherwise show up as a zero count and be reported as a quiet week — the one failure this whole
# design exists to rule out. Treat "cannot read" as loud failure, never as "no data".
# Fix when it fires: System Settings → Privacy & Security → Full Disk Access → add /bin/bash.
#
# Probing as bash is the right test since 2026-08-17, because bash is now the ONLY thing that
# touches the container — see section 1 for why it did not used to be.
TCC_OK=1
ls "$CONTEXT_DIR" >/dev/null 2>&1 || TCC_OK=0
if [ "$TCC_OK" -eq 1 ]; then
  for probe in "$CONTEXT_DIR"/interactions-*.jsonl; do
    [ -f "$probe" ] || continue
    head -c 1 "$probe" >/dev/null 2>&1 || TCC_OK=0
    break
  done
fi

if [ "$TCC_OK" -eq 0 ]; then
  fail_out "usage review BLOCKED — cannot read the app's data directory (macOS permissions)." \
    "The directory exists but is unreadable from this job, so a zero count here would be a lie," \
    "not a quiet week: $CONTEXT_DIR" \
    "" \
    "Fix: System Settings > Privacy & Security > Full Disk Access > add /bin/bash." \
    "Then re-run with: bash scripts/usage-review-job.sh"
fi

# ------------------------------------------------- 1. stage the window, then count what we staged
# Everything the review pass reads is copied out of the container first, and the pass is pointed at
# the copy. That is not tidiness — it is the fix for the 2026-08-17 failure.
#
# /bin/bash has Full Disk Access, so the loop below reads the container fine. The `claude` child
# does NOT inherit that: its Bash tool runs commands in a sandboxed zsh, and from a launchd job
# there is nobody to answer the resulting TCC prompt, so `opendir` stalls and eventually returns
# "Interrupted system call" instead of a clean denial. The pass cannot tell that apart from a slow
# disk, so it retried — for 19 hours, spending its entire $3 budget and running out one tool call
# short of writing its digest.
#
# So: bash copies (it can), claude reads the copy (no TCC in the path at all).
#
# The staging copy holds real transcripts. It is wiped at the start of every run and lives under
# build/, which is gitignored — same machine, never committed, never uploaded.
rm -rf "$STAGING"
mkdir -p "$STAGING" || fail_out "usage review FAILED — could not create the staging dir $STAGING."

# Counting as we copy is what keeps this cheap. A week where the user barely touched the app has
# nothing to say, and spending a Claude session to discover that — every Monday — is how a good
# habit turns into noise the user mutes.
#
# errors-*.log is staged too: a failure that aborts before an interaction record exists (e.g.
# noSpeechDetected) appears nowhere else, and run 2 found a real pattern there.
INTERACTIONS=0
SIGNALS=0
for f in "$CONTEXT_DIR"/interactions-*.jsonl "$CONTEXT_DIR"/signals-*.jsonl "$CONTEXT_DIR"/errors-*.log; do
  [ -f "$f" ] || continue
  [ -z "$(find "$f" -mtime "-${DAYS}" 2>/dev/null)" ] && continue
  cp "$f" "$STAGING/" || fail_out "usage review FAILED — could not stage $f into $STAGING."
  case "$(basename "$f")" in
    interactions-*) INTERACTIONS=$((INTERACTIONS + $(wc -l < "$f"))) ;;
    signals-*)      SIGNALS=$((SIGNALS + $(wc -l < "$f"))) ;;
  esac
done

# A short copy would understate the week just as quietly as a TCC denial did, so verify it rather
# than trusting cp's exit status alone.
STAGED_LINES=0
for f in "$STAGING"/interactions-*.jsonl; do
  [ -f "$f" ] || continue
  STAGED_LINES=$((STAGED_LINES + $(wc -l < "$f")))
done
if [ "$STAGED_LINES" -ne "$INTERACTIONS" ]; then
  fail_out "usage review FAILED — staged copy is short: $STAGED_LINES of $INTERACTIONS lines." \
    "Source: $CONTEXT_DIR" \
    "Staging: $STAGING" \
    "The app may have been writing mid-copy. Re-run with: bash scripts/usage-review-job.sh"
fi

echo "In the last ${DAYS} days: $INTERACTIONS interactions, $SIGNALS outcome signals."
echo "Staged to $STAGING for the review pass."

MIN_INTERACTIONS="${REVIEW_MIN_INTERACTIONS:-40}"
if [ "$INTERACTIONS" -lt "$MIN_INTERACTIONS" ]; then
  echo "Below the $MIN_INTERACTIONS-interaction floor — nothing worth reviewing. Exiting quietly."
  echo "=== Usage review finished (skipped): $(date '+%H:%M:%S') ==="
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== --dry-run: skipping the Claude pass. Done: $(date '+%H:%M:%S') ==="
  exit 0
fi

# ---------------------------------------------------------------- 2. review
# Prompt via temp file, not a nested heredoc in a command substitution: macOS ships bash 3.2, which
# mis-parses an apostrophe in that position. Same workaround as model-audit-job.sh.
PROMPT_FILE="$(mktemp -t wsusagereview)"
trap 'rm -f "$PROMPT_FILE" "${KILLED_MARKER:-}"' EXIT
cat > "$PROMPT_FILE" <<EOF
You are the weekly usage-review job for WhisperShortcut (repo: $REPO).

Your job is to turn one week of this user's ACTUAL usage into at most three concrete, evidence-backed
proposals for making the app better to use. You are not writing code today.

## Before anything else

Read $LEDGER in full, including the "Rejected — do not re-propose" table. Re-proposing something
the user already turned down is the single fastest way to make this job worthless. If your best
finding is already in there under any status, drop it and move to the next one.

## Data (all local, none of it is in git)

Everything you need has ALREADY been copied here for you:
    $STAGING

It holds exactly the files that fall in the review window — nothing to filter by date, no other
directory to visit.

- interactions-YYYY-MM-DD.jsonl — one record per interaction. Modes: transcription, prompt,
  geminiChat. Schema and caveats are documented in .cursor/skills/analyze-user-interactions/SKILL.md
  — read that skill and follow its procedure.
- signals-YYYY-MM-DD.jsonl — outcome signals: what the user DID after an interaction.
  kind=pasted (result reached the cursor — it worked), kind=dictationRestart (a dictation started
  within 20s of an unpasted transcript — it did not work), kind=cancelledWhileProcessing (killed
  before a result existed). Fields: ts, kind, refTs (the interaction it judges), mode, gapMs, detail.
  Design and caveats: plans/active/outcome-signals.md — read it.
- errors-YYYY-MM-DD.log — failures that aborted before an interaction record existed. These are
  invisible to the signal stream by construction, so read them; they are the only trace of a
  dictation that produced nothing at all.

DO NOT read $CONTEXT_DIR directly. That path is unreadable from your Bash tool — the sandbox has
no Full Disk Access grant, and a read there does not fail cleanly, it HANGS. A previous run burned
19 hours and its whole budget retrying one directory listing. If a command against that path stalls
or reports "Interrupted system call", do not retry it: use $STAGING, which is a complete copy.

Review the last $DAYS days. This week: $INTERACTIONS interactions, $SIGNALS signals.

## How to weigh evidence

Signals outrank prose. A dictationRestart is the user telling you a transcript was unusable; your
own reading of whether a transcript "looks good" is an opinion about output from the same family of
model that produced it. So: rank candidate problems by signal count first, and only then read the
text of the flagged interactions to work out what actually went wrong.

Bar for an entry: at least 2 occurrences, OR one negative signal plus one supporting example. A
single anecdote goes in the digest as "observed, insufficient data" and NOT in the ledger.

Caveats you must respect:
- The signal stream started 2026-08-02. Earlier days have interactions but no signals; absence of a
  signal before that date means nothing.
- dictationRestart carries detail.autoPasteAvailable. Where that is "false" the signal is unreliable
  (no auto-paste in that build, so a manual paste is invisible) — discount those.
- Live-meeting dictation segments never emit dictationRestart by design.

## Output

Write these IN THIS ORDER. The digest comes first because the job treats its absence as a failed
run — if you are cut off (budget, timeout) after the digest, the week is still reported; if you are
cut off before it, the whole run is wasted no matter how much analysis you finished.

1. Write a short digest to: $DIGEST
2. Append at most 3 rows to the "Ideas" table in $LEDGER, following the rules stated at the top of
   that file. Give each a fresh stable ID (I1, I2, …). Add one row to its "Run log" table.

The digest's FIRST line must be a single-line verdict in exactly this form, because the job reads it
back for the notification and the mail subject:

    VERDICT: <one sentence, max 120 chars, naming the top finding or "nothing actionable this week">

Then: what the numbers were (interaction and signal counts by mode, restart rate, paste rate), the
proposals with their evidence, and anything observed but under the evidence bar. Keep it tight — it
is read once a week by one person deciding whether to act.

## Hard constraints

- Do NOT change any code, prompts, defaults, or settings.
- Do NOT create files in plans/active/ — proposals live in the ledger until the user approves one.
- Do NOT commit or push anything.
- Do NOT put user content (transcripts, chat text, selected text) in the ledger. Short quoted
  fragments are fine in the digest where they are the evidence; the ledger stays summary-level.
- If the week genuinely contains nothing actionable, say so in the verdict and add no ledger rows.
  A quiet week reported honestly is a good outcome, and padding it is how the ledger dies.
EOF

echo "Review pass: model=$REVIEW_MODEL effort=$REVIEW_EFFORT budget=\$$REVIEW_BUDGET_USD"

# The budget cap bounds what a stuck run COSTS, but not how long it runs — the 2026-08-17 run sat
# there for 19 hours before the cap caught it, which meant a whole day passed before the failure
# mail arrived. macOS ships no `timeout`, so: run claude in the background and shoot it ourselves.
# The sentinel distinguishes "we killed it" from "it died on its own", since both surface as a
# non-zero status.
REVIEW_TIMEOUT_SECS="${REVIEW_TIMEOUT_SECS:-2700}"
KILLED_MARKER="$(mktemp -t wsreviewkill)"
rm -f "$KILLED_MARKER"

claude -p --dangerously-skip-permissions \
  --model "$REVIEW_MODEL" --effort "$REVIEW_EFFORT" --max-budget-usd "$REVIEW_BUDGET_USD" \
  "$(cat "$PROMPT_FILE")" 2>&1 &
CLAUDE_PID=$!

( sleep "$REVIEW_TIMEOUT_SECS"
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
  # A job that silently stops running looks exactly like a week with nothing to report. Say it broke.
  if [ -f "$KILLED_MARKER" ]; then
    WHY="usage review TIMED OUT — killed after ${REVIEW_TIMEOUT_SECS}s without finishing."
  elif [ $STATUS -ne 0 ]; then
    WHY="usage review FAILED — claude exited with status $STATUS."
  else
    WHY="usage review INCOMPLETE — the pass wrote no digest."
  fi
  rm -f "$KILLED_MARKER"
  fail_out "$WHY" \
    "Data was there: $INTERACTIONS interactions, $SIGNALS signals in the last ${DAYS} days." \
    "Log: $REPO/build/logs/usage-review.log" \
    "Re-run manually with: bash scripts/usage-review-job.sh"
fi

# One stable path to open the newest digest.
ln -sf "$(basename "$DIGEST")" "$REVIEW_DIR/LATEST.md"

VERDICT="$(head -1 "$DIGEST" | sed 's/^VERDICT:[[:space:]]*//')"
[ -n "$VERDICT" ] || VERDICT="Digest written (no verdict line found)"
report_out "WhisperShortcut usage review — $VERDICT" "$DIGEST"
notify "WhisperShortcut usage review" "$VERDICT"
echo "VERDICT: $VERDICT"
echo "Digest: $DIGEST"
echo "=== Usage review finished: $(date '+%Y-%m-%d %H:%M:%S') ==="
