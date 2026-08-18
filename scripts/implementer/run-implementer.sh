#!/usr/bin/env bash
# Autonomous implementer runner — `bash scripts/implementer/run-implementer.sh`.
#
# Takes the topmost BUILD/OPEN row from plans/implementer-queue.md, lets the build agent
# (cursor-agent by default — "Cursor builds, Claude judges") implement it in a fresh worktree
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
#      relaunches YOUR MAIN build afterwards, never the unreviewed branch build.
#
# What this script may never do: push to main, merge, release, submit to the App Store, edit
# files in the main checkout, or touch paths outside the scope allowlist. These are checks in
# the script, not requests in a prompt — an agent cannot skip what it does not control.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
QUEUE_REL="plans/implementer-queue.md"
LEDGER_REL="plans/implementer-log.md"
QUEUE_FILE="${REPO_ROOT}/${QUEUE_REL}"

log()  { printf '\033[0;34m[implementer]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[implementer]\033[0m %s\n' "$*"; }
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

BUILD_AGENT="${IMPLEMENTER_BUILD_AGENT:-cursor}"
BUILD_MODEL="${IMPLEMENTER_BUILD_MODEL:-auto}"
REVIEW_AGENT="${IMPLEMENTER_REVIEW_AGENT:-claude}"
REVIEW_MODEL="${IMPLEMENTER_REVIEW_MODEL:-opus}"
TIMEOUT_SECONDS="${IMPLEMENTER_TIMEOUT_SECONDS:-7200}"
SCOPE="${IMPLEMENTER_SCOPE:-app}"
PUSH_PR="${IMPLEMENTER_PUSH_PR:-0}"
MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

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
[[ "$REVIEW_AGENT" == "none" ]] || command -v claude >/dev/null 2>&1 \
    || die "review agent '${REVIEW_AGENT}' needs the claude CLI"
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
log "branch ${BRANCH} · build ${BUILD_AGENT}/${BUILD_MODEL} · review ${REVIEW_AGENT}/${REVIEW_MODEL} · scope ${SCOPE}"
if [[ "$DRY_RUN" == "1" ]]; then
    log "--dry-run: preflight OK, eligible row found, stopping before the worktree."
    exit 0
fi
mkdir -p "$RUN_DIR"

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
    (
        cd "$WT_DIR" || exit 97
        case "$BUILD_AGENT" in
            cursor) exec cursor-agent -p --output-format text --force --model "$BUILD_MODEL" "$prompt" ;;
            claude) exec claude -p --model "$BUILD_MODEL" --dangerously-skip-permissions "$prompt" ;;
        esac
    ) >"$agent_log" 2>&1 &
    local pid=$!
    ( sleep "$TIMEOUT_SECONDS" && kill -TERM "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid"; local rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    return $rc
}

run_build_agent 1 || fail_run "build agent exited non-zero (timeout or error) — see ${RUN_DIR}/agent-1.log"

# --- Runner-enforced gates -----------------------------------------------------------------
CHANGED_FILES=""
run_static_gates() {
    local commits dirty out_of_scope main_after new_paths overlap
    commits=$(git -C "$WT_DIR" rev-list --count "main..${BRANCH}")
    [[ "$commits" -gt 0 ]] || { echo "GATE FAILED: the agent committed nothing"; return 1; }

    dirty=$(git -C "$WT_DIR" status --porcelain | grep -v -E '^\?\? IMPLEMENTER_NOTES\.md$' | grep -v -E '^\?\? \.env$' || true)
    [[ -z "$dirty" ]] || { echo "$dirty" | sed 's/^/    /'; echo "GATE FAILED: uncommitted or stray files in the worktree"; return 1; }

    CHANGED_FILES=$(git -C "$WT_DIR" diff --name-only "main..${BRANCH}")

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

GATE_OUT=$(run_static_gates) || fail_run "$(echo "$GATE_OUT" | tail -1) — details: ${RUN_DIR}"
[[ -n "$GATE_OUT" ]] && echo "$GATE_OUT"

# Gate: it must build. Worktree-local derivedDataPath, so this never disturbs your own build.
log "gate: xcodebuild (Debug)…"
( cd "$WT_DIR" && xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut \
    -configuration Debug -derivedDataPath "${WT_DIR}/build/DerivedData" build ) \
    >"${RUN_DIR}/build.log" 2>&1 \
    || { tail -40 "${RUN_DIR}/build.log"; fail_run "GATE FAILED: xcodebuild"; }

# Gate: the full test plan. xcodebuild test needs the app stopped (a running instance can take
# the SIGTERM during XCTest bootstrap), so this kills it — and restore_user_app puts YOUR build
# back afterwards, never the branch build.
log "gate: test plan (live roundtrips; kills the running app for the duration)…"
pkill -f "WhisperShortcut.app" 2>/dev/null || true
sleep 1
( cd "$WT_DIR" && set -a && [[ -f .env ]] && . ./.env; set +a
  xcodebuild test -project WhisperShortcut.xcodeproj -scheme WhisperShortcut-AppStore \
    -testPlan WhisperShortcut-AppStore -destination 'platform=macOS' \
    -derivedDataPath "${WT_DIR}/build/DerivedData-AppStore" ) \
    >"${RUN_DIR}/tests.log" 2>&1 \
    || { tail -40 "${RUN_DIR}/tests.log"; fail_run "GATE FAILED: test plan"; }
restore_user_app

FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c . || echo 0)
log "gates green (${FILE_COUNT} files changed)"

# --- Review gate: a DIFFERENT model judges the diff -----------------------------------------
REVIEW_VERDICT="skipped"
if [[ "$REVIEW_AGENT" != "none" ]]; then
    review_once() { # review_once <attempt>
        local attempt="$1"
        local diff_file="${RUN_DIR}/diff-${attempt}.patch"
        local out="${RUN_DIR}/review-${attempt}.md"
        git -C "$WT_DIR" diff "main..${BRANCH}" >"$diff_file"
        log "gate: review by ${REVIEW_AGENT}/${REVIEW_MODEL} (attempt ${attempt})…"
        claude -p --model "$REVIEW_MODEL" --dangerously-skip-permissions "$(cat <<EOF
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
)" >"${RUN_DIR}/review-agent-${attempt}.log" 2>&1
        [[ -f "$out" ]] || { echo "BLOCK"; echo "reviewer wrote no verdict file"; return 1; }
        head -1 "$out"
    }

    VERDICT=$(review_once 1 | tr -d '[:space:]')
    if [[ "$VERDICT" == "BLOCK" ]]; then
        warn "reviewer BLOCKED the first attempt — one rework cycle"
        run_build_agent 2 "${RUN_DIR}/review-1.md" || fail_run "build agent failed during rework"
        GATE_OUT=$(run_static_gates) || fail_run "$(echo "$GATE_OUT" | tail -1) (after rework)"
        log "gate: xcodebuild (after rework)…"
        ( cd "$WT_DIR" && xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut \
            -configuration Debug -derivedDataPath "${WT_DIR}/build/DerivedData" build ) \
            >"${RUN_DIR}/build-2.log" 2>&1 || { tail -40 "${RUN_DIR}/build-2.log"; fail_run "GATE FAILED: xcodebuild (after rework)"; }
        log "gate: test plan (after rework)…"
        pkill -f "WhisperShortcut.app" 2>/dev/null || true; sleep 1
        ( cd "$WT_DIR" && set -a && [[ -f .env ]] && . ./.env; set +a
          xcodebuild test -project WhisperShortcut.xcodeproj -scheme WhisperShortcut-AppStore \
            -testPlan WhisperShortcut-AppStore -destination 'platform=macOS' \
            -derivedDataPath "${WT_DIR}/build/DerivedData-AppStore" ) \
            >"${RUN_DIR}/tests-2.log" 2>&1 || { tail -40 "${RUN_DIR}/tests-2.log"; fail_run "GATE FAILED: test plan (after rework)"; }
        restore_user_app
        VERDICT=$(review_once 2 | tr -d '[:space:]')
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

# --- Report --------------------------------------------------------------------------------
REPORT="${RUN_DIR}/report.md"
{
    echo "VERDICT: implementer READY — queue #${Q_NUM}, ${FILE_COUNT} files, review ${REVIEW_VERDICT}"
    echo
    echo "**Proposal:** ${Q_PROPOSAL}"
    echo "**Falsifier:** ${Q_FALSIFIER}"
    echo "**Source:** ${Q_SOURCE}"
    echo
    echo "## Review it by running it"
    echo
    echo '```bash'
    echo "cd ${WT_DIR} && bash scripts/rebuild-and-restart.sh   # launches the BRANCH build"
    echo '```'
    echo
    echo "When you are done, put your own build back:"
    echo '```bash'
    echo "cd ${REPO_ROOT} && bash scripts/rebuild-and-restart.sh"
    echo '```'
    echo
    echo "## Approve"
    echo
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

report_out "WhisperShortcut implementer READY — #${Q_NUM} ${Q_PROPOSAL:0:60}" "$REPORT"
notify "WhisperShortcut implementer READY" "Queue #${Q_NUM} built and gated — review the branch"
log "DONE. Report: ${REPORT}"
log "Branch ${BRANCH} is ready to dogfood; worktree kept at ${WT_DIR}"
