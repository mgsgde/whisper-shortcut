#!/usr/bin/env bash
# Autonomous implementer runner — `bash scripts/implementer/run-implementer.sh`.
#
# Takes the topmost BUILD/OPEN row from plans/implementer-queue.md, lets the build agent
# (Grok builds from an Opus plan — "Opus plans and judges, Grok builds") implement it in a fresh worktree
# branch, then re-runs every gate DETERMINISTICALLY, has a *different* model review the diff,
# and hands you a branch to dogfood. Your merge is the approval; releases stay with you.
#
# Rung 2 of the autonomy ladder (plans/agent-loops.md). Ported from sabaki.dance's
# specs/2026-08-18-autonomous-implementer-design.md, with three deliberate divergences:
#
#   1. No dev instance to review on — the review artifact is the built app itself. The runner
#      leaves a Debug build in the worktree and tells you how to launch it (dogfood-as-review).
#   2. (was: no push by default — dropped 2026-08-18 when the manual-push convention was
#      lifted. The runner now pushes the branch and opens a PR like Sabaki does; merge is the
#      approval. Set IMPLEMENTER_PUSH_PR=0 to keep a run local.)
#   3. The test gate kills the running app (xcodebuild test requires it) — so the runner
#      relaunches YOUR MAIN build afterwards, never the unreviewed branch build. At the very
#      END of a fully green run it does the opposite on purpose: it leaves the BRANCH build
#      running, so you experience the change the moment it is ready (dogfood-as-review, asked
#      for 2026-09-03). Only after every gate AND the reviewer's APPROVE; a failed run always
#      puts your own build back. Off with IMPLEMENTER_LAUNCH_BRANCH_BUILD=0.
#
# What this script may never do: push to main, merge, release, submit to the App Store, edit
# files in the main checkout, or touch paths outside the scope allowlist. These are checks in
# the script, not requests in a prompt — an agent cannot skip what it does not control.
set -uo pipefail

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


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
QUEUE_REL="plans/implementer-queue.md"
LEDGER_REL="plans/implementer-log.md"
QUEUE_FILE="${REPO_ROOT}/${QUEUE_REL}"

# Diagnostics go to STDERR on purpose: several helpers below have their stdout captured
# (a review verdict, a gate result), and a log line landing in that capture is silent
# corruption. Run 1 died exactly there — the reviewer said APPROVE, the capture read
# "[implementer]gate:review…APPROVE" and the runner called it an unusable verdict.
log()  { printf '\033[0;34m[implementer]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[implementer]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[implementer] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) die "unknown flag: $arg" ;;
    esac
done

# --- Config & preflight --------------------------------------------------------------------
CONFIG_FILE="${HOME}/.config/whispershortcut-implementer/env"
if [[ -f "$CONFIG_FILE" ]]; then
    set -a; # shellcheck disable=SC1090
    source "$CONFIG_FILE"; set +a
fi
[[ "${IMPLEMENTER_ENABLED:-0}" == "1" ]] \
    || die "IMPLEMENTER_ENABLED is not 1 — kill switch engaged (config: ${CONFIG_FILE}; create it with scripts/implementer/install-implementer.sh)"

PLAN_AGENT="${IMPLEMENTER_PLAN_AGENT:-claude}"
PLAN_MODEL="${IMPLEMENTER_PLAN_MODEL:-claude-opus-5}"
PLAN_TIMEOUT_SECONDS="${IMPLEMENTER_PLAN_TIMEOUT_SECONDS:-1800}"
BUILD_AGENT="${IMPLEMENTER_BUILD_AGENT:-cursor}"
BUILD_MODEL="${IMPLEMENTER_BUILD_MODEL:-cursor-grok-4.6-high}"
REVIEW_AGENT="${IMPLEMENTER_REVIEW_AGENT:-claude}"
REVIEW_MODEL="${IMPLEMENTER_REVIEW_MODEL:-claude-opus-5}"
TIMEOUT_SECONDS="${IMPLEMENTER_TIMEOUT_SECONDS:-7200}"
SCOPE="${IMPLEMENTER_SCOPE:-app}"
PUSH_PR="${IMPLEMENTER_PUSH_PR:-0}"
# Cumulative brake. The per-run timeout bounds ONE run; nothing bounded how many runs a month
# could hold, and "flag ten rows and let it work" is exactly the shape of an unforeseen bill.
# Counted in a file, not in the script, so the cap survives a crash mid-run.
MAX_RUNS_PER_MONTH="${IMPLEMENTER_MAX_RUNS_PER_MONTH:-10}"
# The only part of this machinery that spends the app's own provider keys was the live
# transcription roundtrips in the test gate. Off by default: they cost real money per run, and
# what they protect against (a provider changing its API shape) is not what a code change to
# THIS repo usually breaks. Everything else in the plan is offline logic and still runs.
# Set IMPLEMENTER_LIVE_TESTS=1 for a change that touches a provider request path.
LIVE_TESTS="${IMPLEMENTER_LIVE_TESTS:-0}"
# After a fully green run, leave the BRANCH build running so you experience the change the
# moment it is ready, instead of having to launch it yourself. Only ever after every gate AND
# the reviewer's APPROVE — a failed run always puts your own build back. Set 0 for the old
# behaviour (your main build is restored and the branch build waits for you).
LAUNCH_BRANCH_BUILD="${IMPLEMENTER_LAUNCH_BRANCH_BUILD:-1}"
if [[ "$LIVE_TESTS" == "1" ]]; then
    TEST_SKIP_ARGS=()
else
    # Both suites carry "(live)" in their @Suite name — that is the convention to look for when
    # adding one. Anything else in the plan stubs URLProtocol and costs nothing.
    TEST_SKIP_ARGS=(
        -skip-testing:WhisperShortcutTests/TranscriptionRoundtripTests
        -skip-testing:WhisperShortcutTests/LLMProviderRoundtripTests
    )
fi
MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

# --- Usage limits are not failures ----------------------------------------------------------
# `claude -p` and cursor-agent both EXIT when the plan quota is hit; auto-continue is
# interactive-only. Treating that as a build failure mailed FAILED, kept a worktree nobody
# could learn anything from, and that worktree then blocked the next tick. The helpers below
# recognise it and wait the reset out instead.
USAGE_LIMIT_STAMP="${HOME}/.config/whispershortcut-implementer/usage-limit-until"
# How long a single run may sit waiting before it gives the slot back to the next tick. Two
# hours covers a session limit; a weekly one is beyond any run and must defer.
USAGE_WAIT_CAP_SECONDS="${IMPLEMENTER_USAGE_WAIT_CAP_SECONDS:-7200}"
# shellcheck source=usage-limit.sh
source "${SCRIPT_DIR}/usage-limit.sh"

case "$SCOPE" in
    app)      SCOPE_REGEX='^(WhisperShortcut/|WhisperShortcutTests/|plans/implementer-)' ;;
    app-docs) SCOPE_REGEX='^(WhisperShortcut/|WhisperShortcutTests/|plans/|README\.md$|\.cursor/)' ;;
    *) die "unknown IMPLEMENTER_SCOPE '${SCOPE}'" ;;
esac

case "$BUILD_AGENT" in
    cursor) command -v cursor-agent >/dev/null 2>&1 || die "cursor-agent not found (curl https://cursor.com/install -fsS | bash)" ;;
    claude) command -v claude       >/dev/null 2>&1 || die "claude CLI not found" ;;
    *) die "unknown IMPLEMENTER_BUILD_AGENT '${BUILD_AGENT}'" ;;
esac
[[ "$REVIEW_AGENT" == "none" || "$REVIEW_AGENT" == "claude" ]] \
    || die "IMPLEMENTER_REVIEW_AGENT must be claude or none — Cursor does not judge (config: ${CONFIG_FILE})"
[[ -z "$PLAN_AGENT" || "$PLAN_AGENT" == "claude" ]] \
    || die "IMPLEMENTER_PLAN_AGENT must be claude or empty — Cursor does not plan (config: ${CONFIG_FILE})"
if [[ "$REVIEW_AGENT" != "none" || -n "$PLAN_AGENT" ]]; then
    command -v claude >/dev/null 2>&1 || die "plan/review needs the claude CLI"
fi
if [[ "$PUSH_PR" == "1" ]]; then
    command -v gh >/dev/null 2>&1 || die "IMPLEMENTER_PUSH_PR=1 but gh is not installed"
    gh auth status >/dev/null 2>&1 || die "IMPLEMENTER_PUSH_PR=1 but gh is not authenticated"
fi

# One run at a time. mkdir is atomic and macOS ships no flock(1).
LOCK_DIR="/tmp/whispershortcut-implementer.lock.d"
mkdir "$LOCK_DIR" 2>/dev/null || die "another implementer run is active (${LOCK_DIR})"
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

CURRENT_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null)
[[ "$CURRENT_BRANCH" == "main" ]] || die "main checkout is on '${CURRENT_BRANCH}', expected main"

# --- Monthly run budget -------------------------------------------------------------------
COUNTER_FILE="${HOME}/.config/whispershortcut-implementer/runs-$(date +%Y-%m)"
RUNS_THIS_MONTH=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
if [[ "$RUNS_THIS_MONTH" -ge "$MAX_RUNS_PER_MONTH" ]]; then
    die "monthly run budget exhausted: ${RUNS_THIS_MONTH}/${MAX_RUNS_PER_MONTH} runs in $(date +%Y-%m).
Each run spends build-agent quota and a few live API calls in the test gate. Raise it with
IMPLEMENTER_MAX_RUNS_PER_MONTH in ${CONFIG_FILE}, or wait for the month to roll over."
fi

# --- Pick the topmost eligible queue row ---------------------------------------------------
[[ -f "$QUEUE_FILE" ]] || die "queue file missing: ${QUEUE_FILE}"
ROW=$(grep -E '^\| *[0-9]+ *\|' "$QUEUE_FILE" | awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    trim($6) == "BUILD" && trim($7) == "OPEN" { print; exit }')
if [[ -z "$ROW" ]]; then
    log "no BUILD/OPEN row in the queue — nothing to do."
    exit 0
fi
row_field() { echo "$ROW" | awk -F'|' -v n="$1" 'function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s} {print trim($n)}'; }
Q_NUM=$(row_field 2); Q_SOURCE=$(row_field 3); Q_PROPOSAL=$(row_field 4); Q_FALSIFIER=$(row_field 5)

SLUG="q${Q_NUM}-$(date +%Y%m%d)"
BRANCH="implementer/${SLUG}"
WT_DIR="${REPO_ROOT}/.claude/worktrees/implementer-${SLUG}"
RUN_DIR="${REPO_ROOT}/build/implementer/$(date +%F)-${SLUG}"

log "queue row #${Q_NUM}: ${Q_PROPOSAL:0:90}…"
log "branch ${BRANCH} · plan ${PLAN_AGENT:-none}/${PLAN_MODEL} · build ${BUILD_AGENT}/${BUILD_MODEL} · review ${REVIEW_AGENT}/${REVIEW_MODEL} · scope ${SCOPE}"
if [[ "$DRY_RUN" == "1" ]]; then
    log "--dry-run: preflight OK, eligible row found, stopping before the worktree."
    exit 0
fi
mkdir -p "$RUN_DIR"
# Counted before the agent starts: a run that dies halfway still spent quota, and a counter
# that only increments on success would let a crash loop run unbounded.
echo $((RUNS_THIS_MONTH + 1)) >"$COUNTER_FILE"
log "monthly budget: run $((RUNS_THIS_MONTH + 1)) of ${MAX_RUNS_PER_MONTH}"

# --- Reporting helpers ---------------------------------------------------------------------
notify() {
    osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" >/dev/null 2>&1 || true
}
report_out() { # report_out <subject> <body-file>
    python3 "${REPO_ROOT}/scripts/send-report-mail.py" --to "$MAIL_TO" --subject "$1" --body-file "$2" \
        || warn "could not send mail — see ${2}"
}

# The test gate below kills the app. Remember whether it was running, so we can put the user's
# world back exactly as we found it — with THEIR build, never the branch build.
MAIN_APP="${REPO_ROOT}/build/DerivedData/Build/Products/Debug/WhisperShortcut.app"
APP_WAS_RUNNING=0
pgrep -f "WhisperShortcut.app" >/dev/null 2>&1 && APP_WAS_RUNNING=1

restore_user_app() {
    [[ "$APP_WAS_RUNNING" == "1" ]] || return 0
    pgrep -f "WhisperShortcut.app" >/dev/null 2>&1 && return 0
    if [[ -d "$MAIN_APP" ]]; then
        log "relaunching your main build (never the branch build)"
        open "$MAIN_APP" || warn "could not relaunch ${MAIN_APP}"
    else
        warn "your app was running but there is no build at ${MAIN_APP} — relaunch it yourself"
    fi
}

# The counterpart to restore_user_app, and deliberately its opposite: this hands you the branch
# build to live in. It runs only at the very end of a fully green run, so an unreviewed or
# broken build never becomes the app you dictate with. Every earlier call site still restores
# YOUR build — mid-run the branch has not been judged yet.
BRANCH_APP="${WT_DIR}/build/DerivedData/Build/Products/Debug/WhisperShortcut.app"
launch_branch_build() {
    [[ "$LAUNCH_BRANCH_BUILD" == "1" ]] || return 0
    if [[ ! -d "$BRANCH_APP" ]]; then
        warn "no branch build at ${BRANCH_APP} — leaving your own build running"
        return 0
    fi
    log "launching the BRANCH build so you can try it now: ${BRANCH}"
    pkill -f "WhisperShortcut.app" 2>/dev/null || true
    sleep 1
    open "$BRANCH_APP" || { warn "could not launch the branch build — restoring yours"; restore_user_app; return 0; }
    BRANCH_BUILD_RUNNING=1
}
BRANCH_BUILD_RUNNING=0

fail_run() { # fail_run <reason>
    warn "$1"
    warn "worktree kept for post-mortem: ${WT_DIR}"
    warn "(remove with: git -C '${REPO_ROOT}' worktree remove --force '${WT_DIR}')"
    warn "logs: ${RUN_DIR}"
    restore_user_app
    local note="${RUN_DIR}/failure.md"
    {
        echo "VERDICT: implementer FAILED — ${1}"
        echo
        echo "Queue #${Q_NUM}: ${Q_PROPOSAL}"
        echo "Branch: ${BRANCH}"
        echo "Worktree kept: ${WT_DIR}"
        echo "Logs: ${RUN_DIR}"
    } >"$note"
    report_out "WhisperShortcut implementer FAILED (#${Q_NUM})" "$note"
    notify "WhisperShortcut implementer FAILED" "$1"
    exit 1
}

# --- Calling an agent CLI -------------------------------------------------------------------
# One place, three callers (plan, build, review). It used to be three copies of the same
# pid/watchdog dance, which is why the usage-limit wait could only be added once here.
#
# Returns the agent's exit code, or 77 when a usage limit is in force past this run's wait cap
# — the caller answers that with defer_for_usage_limit, never with fail_run.
#
#   run_agent_cli <agent> <model> <timeout_s> <log_file> <prompt>
run_agent_cli() {
    local agent="$1" model="$2" timeout_s="$3" log_file="$4" prompt="$5"
    local attempt=1 backoff=900 wait_deadline=0 agent_exit pid watchdog attempt_log now reset
    : >"$log_file"
    while :; do
        attempt_log="${log_file}.attempt-${attempt}"
        (
            cd "$WT_DIR" || exit 97
            case "$agent" in
                cursor) exec cursor-agent -p --output-format text --force --model "$model" "$prompt" ;;
                claude) exec claude -p --model "$model" --dangerously-skip-permissions "$prompt" ;;
                *) exit 98 ;;
            esac
        ) >"$attempt_log" 2>&1 &
        pid=$!
        if [[ "$timeout_s" -gt 0 ]]; then
            ( sleep "$timeout_s" && kill -TERM "$pid" 2>/dev/null ) &
            watchdog=$!
        else
            watchdog=""
        fi
        wait "$pid"; agent_exit=$?
        if [[ -n "$watchdog" ]]; then kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null; fi
        # Appended, never moved: a retried call must leave the earlier attempts in the log, and
        # the caller reads the file by name.
        cat "$attempt_log" >>"$log_file"
        if [[ $agent_exit -eq 0 ]]; then
            rm -f "$USAGE_LIMIT_STAMP" "$attempt_log"
            return 0
        fi
        if ! usage_limit_in_log "$attempt_log"; then
            rm -f "$attempt_log"
            return "$agent_exit"
        fi
        now=$(date +%s)
        reset=$(parse_usage_reset_epoch "$attempt_log" || true)
        (( wait_deadline == 0 )) && wait_deadline=$((now + USAGE_WAIT_CAP_SECONDS))
        if [[ -n "$reset" && "$reset" =~ ^[0-9]+$ ]]; then
            if (( reset > wait_deadline )); then
                echo "$reset" >"$USAGE_LIMIT_STAMP"; rm -f "$attempt_log"; return 77
            fi
        else
            # No parseable reset time — the message said "limit" but not when. Back off
            # geometrically rather than hammering the API every minute.
            reset=$((now + backoff))
            if (( reset > wait_deadline )); then
                echo $((now + 3600)) >"$USAGE_LIMIT_STAMP"; rm -f "$attempt_log"; return 77
            fi
            backoff=$(( backoff < 3600 ? backoff * 2 : 3600 ))
        fi
        echo "$reset" >"$USAGE_LIMIT_STAMP"
        log "${agent} hit a usage/rate limit — waiting until $(format_epoch "$reset") (attempt ${attempt}), then retrying. Cap $(format_epoch "$wait_deadline")."
        wait_until_epoch "$reset"
        attempt=$((attempt + 1))
        rm -f "$attempt_log"
    done
}

# The opposite of fail_run: nothing is wrong with the row, the machine simply has no quota
# right now. Leave no trace that would block the next tick — the worktree and branch go, the
# queue row stays BUILD/OPEN, and the monthly counter is refunded because this run built
# nothing. Exit 0: the tick must not report a failure either.
defer_for_usage_limit() {
    local until
    until=$(cat "$USAGE_LIMIT_STAMP" 2>/dev/null || echo $(( $(date +%s) + 3600 )))
    warn "LLM usage limit in force until $(format_epoch "$until") — cleaning up so the next tick retries. Queue row #${Q_NUM} stays BUILD/OPEN."
    restore_user_app
    echo "$RUNS_THIS_MONTH" >"$COUNTER_FILE"
    if [[ -n "${WT_DIR:-}" && -e "$WT_DIR" ]]; then
        git -C "$REPO_ROOT" worktree remove --force "$WT_DIR" 2>/dev/null || rm -rf "$WT_DIR"
        git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
    fi
    [[ -n "${BRANCH:-}" ]] && git -C "$REPO_ROOT" branch -D "$BRANCH" 2>/dev/null
    log "deferred — nothing built, nothing spent."
    exit 0
}

# --- Worktree setup ------------------------------------------------------------------------
[[ -e "$WT_DIR" ]] && die "worktree dir already exists: ${WT_DIR} (clean up the previous run first)"
mkdir -p "$(dirname "$WT_DIR")"
git -C "$REPO_ROOT" worktree add "$WT_DIR" -b "$BRANCH" main >/dev/null 2>&1 \
    || die "git worktree add failed"

# The live test plan sources .env for provider keys; without it every roundtrip test skips and
# the gate would pass on an untested change. Copy (never symlink) and keep it 600.
if [[ -f "${REPO_ROOT}/.env" ]]; then
    cp "${REPO_ROOT}/.env" "${WT_DIR}/.env"
    chmod 600 "${WT_DIR}/.env"
else
    warn "no .env at repo root — live roundtrip tests will skip in the gate"
fi

MAIN_STATUS_BEFORE=$(git -C "$REPO_ROOT" status --porcelain | sort)

# --- Plan (Opus decides HOW; Grok types) ---------------------------------------------------
# The planner writes exactly one file and is forbidden to touch anything else — enforced
# afterwards, not asked for in the prompt. A planner that edits code would put changes into
# the branch that no gate has looked at yet, and the build agent would inherit them as base.
PLAN_FILE_REL="plans/implementer-plans/row-${Q_NUM}.md"
PLAN_CLAUSE=""

run_plan_agent() {
    if [[ -z "$PLAN_AGENT" ]]; then
        warn "plan step DISABLED (IMPLEMENTER_PLAN_AGENT is empty) — the build agent gets the raw queue row"
        return 0
    fi

    local out="${RUN_DIR}/plan.log"
    local prompt="You are the PLANNING agent of the autonomous implementer. You decide HOW this change is made; a different, cheaper model then executes your plan literally. You do not write code, and you do not run the test suite.

Your working directory is a git worktree on branch ${BRANCH}, based on main. Treat it as the entire world.

Plan this row from ${QUEUE_REL}:
- Queue #: ${Q_NUM}
- Source: ${Q_SOURCE}
- Proposal: ${Q_PROPOSAL}
- Falsifier: ${Q_FALSIFIER}

Read before you write: .cursor/skills/implement-proposal/SKILL.md (the build agent's playbook — your plan has to fit it), the repo rules in AGENTS.md and .cursor/rules/index.mdc, and the real files this change touches. Read code rather than guessing at it; that reading is the whole value of this step.

Then write EXACTLY ONE file: ${PLAN_FILE_REL}. Create no other file, modify no existing file, make no commit, push nothing. A deterministic check runs afterwards and fails the entire run if anything else in the worktree changed.

The plan contains, in this order:
1. What the row asks for, in one paragraph — and what it explicitly does NOT ask for.
2. The files to touch, each with its change in one line. Real paths you have opened, not guesses.
3. The tests: which file, which cases. For a bug fix, the regression case that fails before the change and passes after.
4. The falsifier: name the exact metric, log filter or outcome signal it will be read from, and state what must be instrumented for it to be measurable ON THE DAY THIS SHIPS. If that metric does not exist yet, the instrumentation is part of this change and belongs in the file list.
5. The commits, in order, each with its subject line and its paths.
6. Traps: the repo rules that bite here (DebugLogger only, English-only UI text, AppState transitions, rebuild-and-restart is the runner's job not yours, README must change with user-facing features) and the edge cases the tests must cover.
7. What you decided is out of scope, one line each, with the reason.

Allowed paths for the implementation match ${SCOPE_REGEX}. If the row cannot be implemented inside that allowlist, do not plan around it: write the file with a leading 'BLOCKED' section naming the paths it would need. That is a useful answer, and it is the only case where a plan may end without a file list.

Be concrete and short. Your reader is an agent that will follow you literally."

    local head_before status_before plan_exit
    head_before=$(git -C "$WT_DIR" rev-parse HEAD)
    status_before=$(git -C "$WT_DIR" status --porcelain -uall | sort)
    mkdir -p "$(dirname "${WT_DIR}/${PLAN_FILE_REL}")"

    log "planning (${PLAN_AGENT}/${PLAN_MODEL}, timeout $((PLAN_TIMEOUT_SECONDS / 60)) min) — log: ${out}"
    plan_exit=0
    run_agent_cli "$PLAN_AGENT" "$PLAN_MODEL" "$PLAN_TIMEOUT_SECONDS" "$out" "$prompt" || plan_exit=$?
    # A quota is not a verdict on this row. Nothing has been built yet, so give the slot back.
    (( plan_exit == 77 )) && defer_for_usage_limit
    [[ $plan_exit -eq 0 ]] || fail_run "planning agent exited ${plan_exit} (timeout or error) — see ${out}"

    [[ "$(git -C "$WT_DIR" rev-parse HEAD)" == "$head_before" ]] \
        || fail_run "GATE FAILED: the planning agent committed — a planner that commits puts code into the branch that no gate has judged"
    local stray
    stray=$(git -C "$WT_DIR" status --porcelain -uall | sort | grep -v -F " ${PLAN_FILE_REL}" || true)
    if [[ "$stray" != "$status_before" ]]; then
        diff <(echo "$status_before") <(echo "$stray") | sed 's/^/    /'
        fail_run "GATE FAILED: the planning agent changed something other than ${PLAN_FILE_REL} (above)"
    fi

    [[ -s "${WT_DIR}/${PLAN_FILE_REL}" ]] || fail_run "the planning agent wrote no plan at ${PLAN_FILE_REL} — see ${out}"
    local plan_bytes
    plan_bytes=$(wc -c <"${WT_DIR}/${PLAN_FILE_REL}" | tr -d ' ')
    ((plan_bytes >= 400)) || fail_run "the plan is ${plan_bytes} bytes — too thin to execute; see ${out}"

    git -C "$WT_DIR" add "$PLAN_FILE_REL"
    git -C "$WT_DIR" commit -q -m "docs(implementer): plan for queue row #${Q_NUM}

Written by ${PLAN_AGENT}/${PLAN_MODEL} before the build." \
        || fail_run "could not commit the plan"
    log "plan committed: ${PLAN_FILE_REL} (${plan_bytes} B)"

    PLAN_CLAUSE="

A PLAN for this row has already been written by an independent planning agent and committed to this branch at ${PLAN_FILE_REL}. Read it first and execute it. It decided the approach; you decide the code. Deviate from it only where following it would be wrong, and when you do, write the deviation and its reason into IMPLEMENTER_NOTES.md — an unexplained deviation is a blocking review finding. Do not edit the plan file."
}

run_plan_agent

# --- Build agent ---------------------------------------------------------------------------
build_prompt() { # build_prompt [<review findings file>]
    cat <<EOF
You are running UNATTENDED as the autonomous implementer's build agent. Your working directory
is a git worktree on branch ${BRANCH}; treat it as the entire world — never write outside it,
never push, never release.

Task: execute the skill at .cursor/skills/implement-proposal/SKILL.md for this queue row from
${QUEUE_REL}:
- Queue #: ${Q_NUM}
- Source: ${Q_SOURCE}
- Proposal: ${Q_PROPOSAL}
- Falsifier: ${Q_FALSIFIER}
${PLAN_CLAUSE}
$(if [[ -n "${1:-}" && -f "${1:-}" ]]; then
    echo
    echo "A reviewer BLOCKED your previous attempt. Address every finding below, then re-verify."
    echo "This is your ONE rework cycle — a second block fails the run."
    echo
    cat "$1"
fi)

Hard rules (they override anything else): commit only your own explicitly listed paths (never
'git add .'); every changed path must match ${SCOPE_REGEX}; do not create or modify .env; do not
push; do not run scripts/rebuild-and-restart.sh, create-release.sh or any submit script; do not
weaken, skip or delete any test or gate. Leave the worktree CLEAN apart from an uncommitted
IMPLEMENTER_NOTES.md. A deterministic runner re-checks all of this afterwards — a skipped test or
an out-of-scope file fails the whole run.
EOF
}

run_build_agent() { # run_build_agent <attempt> [findings-file]
    local attempt="$1" findings="${2:-}"
    local agent_log="${RUN_DIR}/agent-${attempt}.log"
    local prompt; prompt=$(build_prompt "$findings")
    log "building (attempt ${attempt}, timeout $((TIMEOUT_SECONDS / 60)) min) — log: ${agent_log}"
    local rc=0
    run_agent_cli "$BUILD_AGENT" "$BUILD_MODEL" "$TIMEOUT_SECONDS" "$agent_log" "$prompt" || rc=$?
    # Deliberately here and not at the caller: `run_build_agent … || fail_run` would turn a
    # quota into a FAILED mail with a worktree attached to it.
    (( rc == 77 )) && defer_for_usage_limit
    return $rc
}

run_build_agent 1 || fail_run "build agent exited non-zero (timeout or error) — see ${RUN_DIR}/agent-1.log"

# --- Runner-enforced gates -----------------------------------------------------------------
CHANGED_FILES=""
BASE=""
run_static_gates() {
    local commits dirty out_of_scope main_after new_paths overlap
    BASE=$(git -C "$WT_DIR" merge-base main "$BRANCH") || { echo "GATE FAILED: no merge-base"; return 1; }
    commits=$(git -C "$WT_DIR" rev-list --count "${BASE}..${BRANCH}")
    [[ "$commits" -gt 0 ]] || { echo "GATE FAILED: the agent committed nothing"; return 1; }

    dirty=$(git -C "$WT_DIR" status --porcelain | grep -v -E '^\?\? IMPLEMENTER_NOTES\.md$' | grep -v -E '^\?\? \.env$' || true)
    [[ -z "$dirty" ]] || { echo "$dirty" | sed 's/^/    /'; echo "GATE FAILED: uncommitted or stray files in the worktree"; return 1; }

    CHANGED_FILES=$(git -C "$WT_DIR" diff --name-only "${BASE}..${BRANCH}")

    # Pollution check. The main checkout is shared with parallel sessions, so only paths that
    # changed there AND appear in the agent's diff are attributable to the agent.
    main_after=$(git -C "$REPO_ROOT" status --porcelain | sort)
    if [[ "$MAIN_STATUS_BEFORE" != "$main_after" ]]; then
        new_paths=$(comm -13 <(echo "$MAIN_STATUS_BEFORE") <(echo "$main_after") | sed 's/^...//')
        overlap=$(grep -Fx -f <(echo "$CHANGED_FILES") <(echo "$new_paths") 2>/dev/null || true)
        if [[ -n "$overlap" ]]; then
            echo "$overlap" | sed 's/^/    /'
            echo "GATE FAILED: files the agent worked on also changed in the MAIN checkout — absolute-path pollution"
            return 1
        fi
        warn "main checkout changed during the build (parallel session, not attributable):"
        echo "$new_paths" | sed 's/^/    /'
    fi

    out_of_scope=$(echo "$CHANGED_FILES" | grep -v -E "$SCOPE_REGEX" || true)
    [[ -z "$out_of_scope" ]] || { echo "$out_of_scope" | sed 's/^/    /'; echo "GATE FAILED: out-of-scope paths for scope '${SCOPE}'"; return 1; }
    return 0
}

run_static_gates || fail_run "static gates failed (see the GATE FAILED line above) — details: ${RUN_DIR}"

# Gate: it must build. Worktree-local derivedDataPath, so this never disturbs your own build.
log "gate: xcodebuild (Debug)…"
( cd "$WT_DIR" && xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut \
    -configuration Debug -derivedDataPath "${WT_DIR}/build/DerivedData" build ) \
    >"${RUN_DIR}/build.log" 2>&1 \
    || { tail -40 "${RUN_DIR}/build.log"; fail_run "GATE FAILED: xcodebuild"; }

# Gate: the full test plan. xcodebuild test needs the app stopped (a running instance can take
# the SIGTERM during XCTest bootstrap), so this kills it — and restore_user_app puts YOUR build
# back afterwards, never the branch build.
log "gate: test plan (live roundtrips: ${LIVE_TESTS} — kills the running app for the duration)…"
pkill -f "WhisperShortcut.app" 2>/dev/null || true
sleep 1
( cd "$WT_DIR" && set -a && [[ -f .env ]] && . ./.env; set +a
  xcodebuild test -project WhisperShortcut.xcodeproj -scheme WhisperShortcut-AppStore \
    -testPlan WhisperShortcut-AppStore -destination 'platform=macOS' \
    "${TEST_SKIP_ARGS[@]}" \
    -derivedDataPath "${WT_DIR}/build/DerivedData-AppStore" ) \
    >"${RUN_DIR}/tests.log" 2>&1 \
    || { tail -40 "${RUN_DIR}/tests.log"; fail_run "GATE FAILED: test plan"; }
restore_user_app

FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c . || echo 0)
log "gates green (${FILE_COUNT} files changed)"

# --- Review gate: a DIFFERENT model judges the diff -----------------------------------------
REVIEW_VERDICT="skipped"
if [[ "$REVIEW_AGENT" != "none" ]]; then
    # Sets REVIEW_HEAD to the verdict's first line. A return value would have to travel out of
    # a command substitution, and a subshell is exactly where defer_for_usage_limit cannot do
    # its job: its `exit 0` would end the substitution, not the run.
    REVIEW_HEAD=""
    review_once() { # review_once <attempt>
        local attempt="$1"
        local diff_file="${RUN_DIR}/diff-${attempt}.patch"
        local out="${RUN_DIR}/review-${attempt}.md"
        git -C "$WT_DIR" diff "${BASE}..${BRANCH}" >"$diff_file"
        log "gate: review by ${REVIEW_AGENT}/${REVIEW_MODEL} (attempt ${attempt})…"
        # The reviewer now runs INSIDE the worktree (run_agent_cli cds there), which is right —
        # it judges the branch — but it also puts a write-capable CLI in the tree whose gates
        # have already run. So the read-only rule is enforced afterwards rather than asked for.
        local head_before status_before
        head_before=$(git -C "$WT_DIR" rev-parse HEAD)
        status_before=$(git -C "$WT_DIR" status --porcelain -uall | sort)
        local prompt; prompt=$(cat <<EOF
You are the REVIEW gate of the autonomous implementer for WhisperShortcut (repo: ${REPO_ROOT}).
You did not write this code and you must not edit it — you judge it. Read-only.

The change is meant to implement:
- Proposal: ${Q_PROPOSAL}
- Falsifier: ${Q_FALSIFIER}
- Source ledger: ${Q_SOURCE}

The diff is at: ${diff_file}
The build agent's own notes (if any): ${WT_DIR}/IMPLEMENTER_NOTES.md

It already passed: build, the full test plan, the scope allowlist, and a clean-tree check. Do
not re-run those. Judge what those gates cannot see:

- Does it actually implement the proposal, or something adjacent that only looks like it?
- Correctness and concurrency: main-thread work in audio/recording paths, unawaited async,
  retain cycles, force-unwraps on user input. This app's known failure mode is a main-thread
  hang — see .cursor/skills/analyze-chat-freeze.
- Is the falsifier measurable once this ships? If the proposal needed instrumentation and the
  diff has none, that is a BLOCK.
- Gate integrity: any weakened, skipped or deleted test, any relaxed threshold, any edited
  falsifier is an automatic BLOCK.
- User-facing feature changes without the matching README.md update (the in-app Chat serves
  README as its documentation) — BLOCK.

Write your verdict to ${out} as markdown. Its FIRST line must be exactly one of:
    APPROVE
    BLOCK
Then the reasoning: for BLOCK, a numbered list of findings, each naming the file and what must
change. Be concrete and short. Nits are not blocking — say them under "Non-blocking".
EOF
)
        local rc=0
        run_agent_cli "$REVIEW_AGENT" "$REVIEW_MODEL" 0 "${RUN_DIR}/review-agent-${attempt}.log" "$prompt" || rc=$?
        (( rc == 77 )) && defer_for_usage_limit
        if [[ "$(git -C "$WT_DIR" rev-parse HEAD)" != "$head_before" ]] \
            || [[ "$(git -C "$WT_DIR" status --porcelain -uall | sort)" != "$status_before" ]]; then
            fail_run "GATE FAILED: the review agent modified the worktree — a reviewer that edits bypasses every gate that already ran"
        fi
        # A review whose verdict cannot be read is NOT a pass: a gate that could not be
        # evaluated has not been cleared.
        if [[ ! -f "$out" ]]; then
            REVIEW_HEAD="BLOCK"
            warn "reviewer wrote no verdict file at ${out} (exit ${rc})"
            return 1
        fi
        REVIEW_HEAD=$(head -1 "$out" | tr -d '[:space:]')
    }

    review_once 1
    VERDICT="$REVIEW_HEAD"
    if [[ "$VERDICT" == "BLOCK" ]]; then
        warn "reviewer BLOCKED the first attempt — one rework cycle"
        run_build_agent 2 "${RUN_DIR}/review-1.md" || fail_run "build agent failed during rework"
        run_static_gates || fail_run "static gates failed after rework (see above)"
        log "gate: xcodebuild (after rework)…"
        ( cd "$WT_DIR" && xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut \
            -configuration Debug -derivedDataPath "${WT_DIR}/build/DerivedData" build ) \
            >"${RUN_DIR}/build-2.log" 2>&1 || { tail -40 "${RUN_DIR}/build-2.log"; fail_run "GATE FAILED: xcodebuild (after rework)"; }
        log "gate: test plan (after rework)…"
        pkill -f "WhisperShortcut.app" 2>/dev/null || true; sleep 1
        ( cd "$WT_DIR" && set -a && [[ -f .env ]] && . ./.env; set +a
          xcodebuild test -project WhisperShortcut.xcodeproj -scheme WhisperShortcut-AppStore \
            -testPlan WhisperShortcut-AppStore -destination 'platform=macOS' \
            "${TEST_SKIP_ARGS[@]}" \
            -derivedDataPath "${WT_DIR}/build/DerivedData-AppStore" ) \
            >"${RUN_DIR}/tests-2.log" 2>&1 || { tail -40 "${RUN_DIR}/tests-2.log"; fail_run "GATE FAILED: test plan (after rework)"; }
        restore_user_app
        review_once 2
        VERDICT="$REVIEW_HEAD"
        [[ "$VERDICT" == "APPROVE" ]] || fail_run "reviewer BLOCKED twice — a human decides now (see ${RUN_DIR}/review-2.md)"
        REVIEW_VERDICT="approved after 1 rework"
    elif [[ "$VERDICT" == "APPROVE" ]]; then
        REVIEW_VERDICT="approved"
    else
        fail_run "reviewer returned an unusable verdict '${VERDICT}' (see ${RUN_DIR}/)"
    fi
    log "review: ${REVIEW_VERDICT}"
fi

# --- Bookkeeping ON THE BRANCH, so it travels with the code ---------------------------------
NOTES_FILE="${WT_DIR}/IMPLEMENTER_NOTES.md"
PR_URL=""
STATUS_VALUE="BRANCH ${BRANCH}"

if [[ "$PUSH_PR" == "1" ]]; then
    git -C "$WT_DIR" push -q -u origin "$BRANCH" || fail_run "git push failed"
    PR_BODY="${RUN_DIR}/pr-body.md"
    {
        echo "Autonomous implementer build for queue row #${Q_NUM} (${Q_SOURCE})."
        echo; echo "**Proposal:** ${Q_PROPOSAL}"; echo "**Falsifier:** ${Q_FALSIFIER}"; echo
        [[ -f "$NOTES_FILE" ]] && cat "$NOTES_FILE" || echo "_No IMPLEMENTER_NOTES.md._"
        echo; echo "---"
        echo "Gates re-run by the runner: build ✓ · test plan ✓ · scope ✓ · review: ${REVIEW_VERDICT}"
        echo; echo "Merge = approval. The App Store release stays with the operator (\`/release\`, \`/submit-appstore\`)."
        echo; echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
    } >"$PR_BODY"
    PR_URL=$(cd "$WT_DIR" && gh pr create --base main --head "$BRANCH" \
        --title "implementer: ${Q_PROPOSAL:0:70}" --body-file "$PR_BODY") || fail_run "gh pr create failed"
    STATUS_VALUE="PR ${PR_URL}"
    log "PR created: ${PR_URL}"
fi

python3 - "${WT_DIR}/${QUEUE_REL}" "$Q_NUM" "$STATUS_VALUE" <<'PY'
import sys
path, qnum, status = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines(keepends=True)
for i, line in enumerate(lines):
    cells = line.split('|')
    if len(cells) > 6 and cells[1].strip() == qnum and cells[6].strip() == 'OPEN':
        cells[6] = f' {status} '
        lines[i] = '|'.join(cells)
        break
else:
    sys.exit(f'queue row {qnum} with Status=OPEN not found')
open(path, 'w').write(''.join(lines))
PY
[[ $? -eq 0 ]] || fail_run "could not flip the queue row on the branch"

printf '| %s | %s | `%s` | %s | build+tests green | OPEN |\n' \
    "$(date +%F)" "$Q_NUM" "$BRANCH" "$REVIEW_VERDICT" >>"${WT_DIR}/${LEDGER_REL}"
git -C "$WT_DIR" add "$QUEUE_REL" "$LEDGER_REL"
git -C "$WT_DIR" commit -q -m "docs(implementer): queue row #${Q_NUM} → ${STATUS_VALUE%% *}, ledger entry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" || fail_run "bookkeeping commit failed"
[[ "$PUSH_PR" == "1" ]] && { git -C "$WT_DIR" push -q || fail_run "push of the bookkeeping commit failed"; }

# --- Open the merge window ------------------------------------------------------------------
# The same shape as the VETO lane one step earlier: you are not asked to approve, you are given
# the chance to object. Silence merges. The window lives OUTSIDE the repo on purpose — the
# runner's own bookkeeping is committed on the branch, and a window recorded there would only
# become visible on main after the merge it is supposed to authorise.
#
# It also serialises the lane: tick.sh starts no new build while a window is open, which
# incidentally fixes an older hole — main's queue row still said BUILD/OPEN after a run, so the
# next day's tick would happily build the same row again on a new branch.
MERGE_WINDOW_DAYS="${IMPLEMENTER_MERGE_WINDOW_DAYS:-2}"
WINDOW_DIR="${HOME}/.local/state/whispershortcut-implementer/merge-windows"
MERGE_DEADLINE=""
if [[ "${IMPLEMENTER_AUTO_MERGE:-1}" == "1" ]]; then
    MERGE_DEADLINE=$(date -v"+${MERGE_WINDOW_DAYS}d" +%F 2>/dev/null || date -d "+${MERGE_WINDOW_DAYS} days" +%F)
    mkdir -p "$WINDOW_DIR"
    {
        echo "QUEUE_NUM=${Q_NUM}"
        echo "BRANCH=${BRANCH}"
        echo "WT_DIR=${WT_DIR}"
        echo "PR_URL=${PR_URL}"
        echo "DEADLINE=${MERGE_DEADLINE}"
        echo "RUN_DIR=${RUN_DIR}"
        echo "VETOED="
    } >"${WINDOW_DIR}/q${Q_NUM}.env"
    log "merge window open until ${MERGE_DEADLINE} — stop it with: bash scripts/implementer/veto.sh ${Q_NUM}"
else
    log "IMPLEMENTER_AUTO_MERGE=0 — no merge window; the branch waits for you."
fi

# --- Report --------------------------------------------------------------------------------
REPORT="${RUN_DIR}/report.md"
launch_branch_build

{
    echo "VERDICT: implementer READY — queue #${Q_NUM}, ${FILE_COUNT} files, review ${REVIEW_VERDICT}"
    echo
    echo "**Proposal:** ${Q_PROPOSAL}"
    echo "**Falsifier:** ${Q_FALSIFIER}"
    echo "**Source:** ${Q_SOURCE}"
    echo
    echo "## Review it by running it"
    echo
    if [[ "$BRANCH_BUILD_RUNNING" == "1" ]]; then
        echo "**The branch build is already running** — the app you are looking at right now is"
        echo "\`${BRANCH}\`, not your own build. Try the change, then put yours back:"
    else
        echo "Launch the branch build yourself:"
        echo '```bash'
        echo "cd ${WT_DIR} && bash scripts/rebuild-and-restart.sh   # launches the BRANCH build"
        echo '```'
        echo
        echo "When you are done, put your own build back:"
    fi
    echo '```bash'
    echo "cd ${REPO_ROOT} && bash scripts/rebuild-and-restart.sh"
    echo '```'
    echo
    echo "## Approve"
    echo
    if [[ -n "$MERGE_DEADLINE" ]]; then
        echo "**You do not have to do anything.** This merges into \`main\` on ${MERGE_DEADLINE}"
        echo "unless you stop it:"
        echo
        echo '```bash'
        echo "cd ${REPO_ROOT} && bash scripts/implementer/veto.sh ${Q_NUM}"
        echo '```'
        echo
        echo "Stopping keeps the branch and the worktree — it closes the window, it does not"
        echo "reject the change. Merging does not release anything: \`create-release.sh\` and the"
        echo "App Store submission are still yours, and so is the parent repo's submodule pointer."
        echo
        echo "Rather have it now than on ${MERGE_DEADLINE}?"
        echo
    fi
    if [[ -n "$PR_URL" ]]; then
        echo "Merge the PR: ${PR_URL}"
    else
        echo '```bash'
        echo "cd ${REPO_ROOT} && git merge --no-ff ${BRANCH}"
        echo "git worktree remove ${WT_DIR}"
        echo '```'
        echo
        echo "(No PR: IMPLEMENTER_PUSH_PR=0 — this repo's convention is that you push manually.)"
    fi
    echo
    echo "## What the build agent says"
    echo
    [[ -f "$NOTES_FILE" ]] && cat "$NOTES_FILE" || echo "_No IMPLEMENTER_NOTES.md was written._"
    echo
    echo "## Files changed"
    echo '```'
    echo "$CHANGED_FILES"
    echo '```'
    echo
    echo "Gates: scope ✓ · clean tree ✓ · xcodebuild ✓ · test plan ✓ · review ${REVIEW_VERDICT}"
    echo "Logs: ${RUN_DIR}"
    echo
    echo "After merging, set the Outcome in ${LEDGER_REL} (MERGED / MERGED+REWORK / DROPPED) —"
    echo "the automation's own falsifier is graded from that column."
} >"$REPORT"

SUBJECT_TAIL=""
[[ -n "$MERGE_DEADLINE" ]] && SUBJECT_TAIL=" — merges ${MERGE_DEADLINE} unless stopped"
report_out "WhisperShortcut implementer READY — #${Q_NUM} ${Q_PROPOSAL:0:60}${SUBJECT_TAIL}" "$REPORT"
if [[ "$BRANCH_BUILD_RUNNING" == "1" ]]; then
    notify "WhisperShortcut implementer READY" "Queue #${Q_NUM} is now RUNNING as ${BRANCH} — try it"
else
    notify "WhisperShortcut implementer READY" "Queue #${Q_NUM} built and gated — review the branch"
fi
log "DONE. Report: ${REPORT}"
log "Branch ${BRANCH} is ready to dogfood; worktree kept at ${WT_DIR}"
