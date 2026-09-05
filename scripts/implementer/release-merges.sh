#!/usr/bin/env bash
# Carry out the merge windows the runner opened — step 1 of the hourly tick.
#
#     bash scripts/implementer/release-merges.sh [--dry-run]
#
# A window that ran out and was not stopped is merged into `main`; a window you stopped is
# closed and its branch handed back to you. This script never DECIDES anything: every outcome
# it carries out was already determined by a veto or by silence, exactly like the VETO lane one
# step earlier. Ported from sabaki.dance's release-decisions.sh + decide.sh (approve path),
# minus the decision database — a state file per window is the whole mechanism here.
#
# Why merging may happen unattended at all: on this repo, `main` is not a release. Users get
# code through `scripts/create-release.sh` and the App Store submission, both of which stay
# with the operator and are unaffected by anything in this file. So the blast radius of a wrong
# merge is a revert, which is what makes this rung 2 rather than rung 3 (plans/agent-loops.md).
#
# The submodule pointer in the PARENT repo is deliberately not touched. That commit says "this
# is the app version I stand behind", and it is not this script's to make.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
QUEUE_REL="plans/implementer-queue.md"
LEDGER_REL="plans/implementer-log.md"
STATE_DIR="${HOME}/.local/state/whispershortcut-implementer"
WINDOW_DIR="${STATE_DIR}/merge-windows"

log()  { printf '\033[0;34m[merge]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[merge]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[merge] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

CONFIG_FILE="${HOME}/.config/whispershortcut-implementer/env"
if [[ -f "$CONFIG_FILE" ]]; then
    set -a; # shellcheck disable=SC1090
    source "$CONFIG_FILE"; set +a
fi
[[ "${IMPLEMENTER_ENABLED:-0}" == "1" ]] || die "IMPLEMENTER_ENABLED is not 1 — kill switch is engaged"
MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"
# Its own switch, separate from IMPLEMENTER_ENABLED: turning the merge lane off must not also
# stop building, and turning building off must not leave a window half-carried-out.
AUTO_MERGE="${IMPLEMENTER_AUTO_MERGE:-1}"
# main is public. Pushing is part of closing a run out — the next tick fast-forwards local main
# from origin/main and would otherwise diverge — but it is the one step that leaves this Mac,
# so it gets a switch of its own.
PUSH_MAIN="${IMPLEMENTER_AUTO_PUSH_MAIN:-1}"
# Commits between the build's base and current main that cannot change a test outcome, so a
# rebase over them needs no re-gate. A FIXED PATH LIST, never a judgement about content:
# WhisperShortcut/, WhisperShortcutTests/, scripts/ and the Xcode project stay outside it, so
# an exempt delta genuinely cannot reach the code under test. Widening this list is a gate
# change and needs the same deliberate act as widening AUTO_CLASSES.
REGATE_EXEMPT_REGEX='^(plans/|\.cursor/|\.agents/|[^/]+\.md$)'

mail_out() { # mail_out <subject> <body-file>
    python3 "${REPO_ROOT}/scripts/send-report-mail.py" --to "$MAIL_TO" --subject "$1" --body-file "$2" \
        || warn "could not send mail — see ${2}"
}
notify() {
    osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" >/dev/null 2>&1 || true
}

[[ -d "$WINDOW_DIR" ]] || { log "no merge windows."; exit 0; }
# Into an array, not a `while read` over a here-string. The gates below run xcodebuild, which
# reads stdin — inside a read loop it swallows the remaining lines, so the first window that
# needed a re-gate silently ate every window after it. Caught in the scratch test on
# 2026-09-05, where window #11 was never processed and nothing said so.
WINDOWS=()
while IFS= read -r f; do [[ -n "$f" ]] && WINDOWS+=("$f"); done < <(
    find "$WINDOW_DIR" -maxdepth 1 -name 'q*.env' 2>/dev/null | sort
)
(( ${#WINDOWS[@]} )) || { log "no merge windows."; exit 0; }

# --- Queue and ledger writers ----------------------------------------------------------------
# On main, in the shared checkout, because a merge window's outcome is about main. The runner's
# own bookkeeping goes on the branch; this is the other half, and the two never write the same
# cell at the same time — the branch cell says BRANCH/PR, this one says what became of it.
set_queue_status() { # set_queue_status <num> <status> [flag]
    python3 - "${REPO_ROOT}/${QUEUE_REL}" "$1" "$2" "${3:-}" <<'PY'
import sys
path, qnum, status, flag = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
for i, line in enumerate(lines):
    cells = line.split('|')
    if len(cells) > 7 and cells[1].strip() == qnum:
        cells[6] = f' {status} '
        if flag:
            cells[5] = f' {flag} '
        # A row that is no longer released must not keep a date `due` could read.
        cells[7] = ' ' if flag == 'ASK' else cells[7]
        lines[i] = '|'.join(cells)
        break
else:
    sys.exit(f'queue row {qnum} not found')
open(path, 'w', encoding='utf-8').write(''.join(lines))
PY
}

set_ledger_outcome() { # set_ledger_outcome <branch> <outcome>
    python3 - "${REPO_ROOT}/${LEDGER_REL}" "$1" "$2" <<'PY'
import sys
path, branch, outcome = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
except OSError:
    sys.exit(0)
for i in range(len(lines) - 1, -1, -1):
    cells = lines[i].split('|')
    if len(cells) > 6 and branch in cells[3]:
        cells[6] = f' {outcome} '
        lines[i] = '|'.join(cells)
        break
else:
    sys.exit(0)
open(path, 'w', encoding='utf-8').write(''.join(lines))
PY
}

commit_bookkeeping() { # commit_bookkeeping <message>
    git -C "$REPO_ROOT" add "$QUEUE_REL" "$LEDGER_REL" 2>/dev/null
    # Pathspec form: a `git commit` with no paths would sweep whatever the operator had staged
    # in the shared checkout into a commit with this message on it.
    git -C "$REPO_ROOT" commit -q -m "$1" -- "$QUEUE_REL" "$LEDGER_REL" \
        || warn "bookkeeping commit failed (nothing staged?)"
}

push_main() {
    [[ "$PUSH_MAIN" == "1" ]] || { log "IMPLEMENTER_AUTO_PUSH_MAIN=0 — main holds the merge locally, push it yourself."; return; }
    git -C "$REPO_ROOT" push -q origin main \
        || warn "push failed — main holds the merge locally; push it by hand, the next tick expects origin/main to be current"
}

# --- One window ------------------------------------------------------------------------------
handle_window() { # handle_window <window-file>
    local file="$1"
    local QUEUE_NUM="" BRANCH="" WT_DIR="" PR_URL="" DEADLINE="" VETOED="" RUN_DIR=""
    # shellcheck disable=SC1090
    source "$file"
    [[ -n "$QUEUE_NUM" && -n "$BRANCH" ]] || { warn "$(basename "$file"): unreadable window file — leaving it for a human"; return; }

    # A branch that is gone has been handled — by a hand-merge, by decide-by-hand, by anything.
    # The branch is the truth; the window file is only a note about it.
    if ! git -C "$REPO_ROOT" show-ref --verify -q "refs/heads/${BRANCH}"; then
        log "#${QUEUE_NUM}: branch ${BRANCH} is gone — already carried out, closing the window."
        [[ "$DRY_RUN" == "1" ]] || rm -f "$file"
        return
    fi

    if [[ -n "$VETOED" ]]; then
        log "#${QUEUE_NUM}: stopped by you — closing the window, the branch stays yours."
        [[ "$DRY_RUN" == "1" ]] && return
        set_queue_status "$QUEUE_NUM" "BRANCH ${BRANCH}" "ASK" || warn "queue write failed"
        set_ledger_outcome "$BRANCH" "MERGE STOPPED"
        commit_bookkeeping "chore(implementer): merge window for #${QUEUE_NUM} stopped by the operator

The branch and its worktree are kept — a stopped merge is not a rejected change.
Merge it yourself, or drop the branch when you are sure.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
        push_main
        rm -f "$file"
        local note="/tmp/ws-merge-stopped-${QUEUE_NUM}.md"
        {
            echo "VERDICT: merge window for queue #${QUEUE_NUM} stopped."
            echo
            echo "Branch ${BRANCH} is kept, so is its worktree at ${WT_DIR}."
            echo "The queue row is ASK now, so no tick will rebuild it."
            echo
            echo "Merge it yourself:  git -C ${REPO_ROOT} merge --ff-only ${BRANCH}"
            echo "Drop it:            git -C ${REPO_ROOT} worktree remove --force ${WT_DIR} && git -C ${REPO_ROOT} branch -D ${BRANCH}"
        } >"$note"
        mail_out "WhisperShortcut implementer — merge #${QUEUE_NUM} stopped" "$note"
        rm -f "$note"
        return
    fi

    if [[ "$AUTO_MERGE" != "1" ]]; then
        log "#${QUEUE_NUM}: IMPLEMENTER_AUTO_MERGE is not 1 — leaving the window open."
        return
    fi
    local today; today=$(date +%F)
    if [[ -n "$DEADLINE" && "$DEADLINE" > "$today" ]]; then
        log "#${QUEUE_NUM}: window runs until ${DEADLINE} — leaving it."
        return
    fi

    # --- Deferrable preflight. Anything here means "not now", never "not ever" ---------------
    [[ -d /tmp/whispershortcut-implementer.lock.d ]] \
        && { log "#${QUEUE_NUM}: a build is in flight — deferring."; return; }
    local current; current=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null)
    [[ "$current" == "main" ]] \
        || { log "#${QUEUE_NUM}: shared checkout is on '${current}' — deferring."; return; }
    [[ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$QUEUE_REL" "$LEDGER_REL")" ]] \
        || { log "#${QUEUE_NUM}: queue or ledger has uncommitted edits — deferring rather than committing yours."; return; }
    [[ -d "$WT_DIR" ]] \
        || { warn "#${QUEUE_NUM}: worktree ${WT_DIR} is gone — cannot verify the branch before merging. Leaving the window."; return; }
    local dirty
    dirty=$(git -C "$WT_DIR" status --porcelain -uall | grep -v -E '^\?\? IMPLEMENTER_NOTES\.md$' || true)
    if [[ -n "$dirty" ]]; then
        echo "$dirty" | sed 's/^/    /'
        warn "#${QUEUE_NUM}: worktree is dirty (above) — refusing to merge changes no gate has seen. Leaving the window."
        return
    fi
    git -C "$REPO_ROOT" fetch -q origin || { log "#${QUEUE_NUM}: fetch failed — deferring."; return; }
    if [[ "$(git -C "$REPO_ROOT" rev-list --count main..origin/main)" != "0" ]]; then
        git -C "$REPO_ROOT" pull -q --ff-only origin main \
            || { log "#${QUEUE_NUM}: main cannot fast-forward to origin/main — deferring, resolve it by hand."; return; }
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "#${QUEUE_NUM}: WOULD merge ${BRANCH} (deadline ${DEADLINE:-none})."
        return
    fi

    # --- Re-gate against the base that will actually receive this ---------------------------
    # The runner's gates ran against the base the branch was cut from. If main has moved since,
    # they no longer say anything about what would land.
    local main_sha base_sha gates_note="unchanged base"
    main_sha=$(git -C "$REPO_ROOT" rev-parse main)
    base_sha=$(git -C "$REPO_ROOT" merge-base main "$BRANCH")
    if [[ "$main_sha" != "$base_sha" ]]; then
        local behind; behind=$(git -C "$REPO_ROOT" rev-list --count "${base_sha}..main")
        log "#${QUEUE_NUM}: main moved ${behind} commit(s) since the build — rebasing ${BRANCH}…"
        if ! git -C "$WT_DIR" rebase main >/tmp/ws-implementer-rebase.log 2>&1; then
            tail -20 /tmp/ws-implementer-rebase.log | sed 's/^/    /'
            git -C "$WT_DIR" rebase --abort >/dev/null 2>&1
            warn "#${QUEUE_NUM}: rebase hit a conflict — resolving that is not something this pipeline claims to do."
            set_queue_status "$QUEUE_NUM" "BRANCH ${BRANCH}" "ASK"
            set_ledger_outcome "$BRANCH" "REBASE CONFLICT"
            commit_bookkeeping "chore(implementer): #${QUEUE_NUM} needs a hand — rebase conflict on merge

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
            push_main
            rm -f "$file"
            local cnote="/tmp/ws-merge-conflict-${QUEUE_NUM}.md"
            {
                echo "VERDICT: merge window for queue #${QUEUE_NUM} needs you — rebase conflict."
                echo
                echo "Branch ${BRANCH} could not be rebased onto main. Worktree kept: ${WT_DIR}"
                echo "The queue row is ASK, so nothing rebuilds it."
            } >"$cnote"
            mail_out "WhisperShortcut implementer — #${QUEUE_NUM} rebase conflict" "$cnote"
            rm -f "$cnote"
            return
        fi
        local non_exempt
        non_exempt=$(git -C "$REPO_ROOT" diff --name-only "$base_sha" main | grep -v -E "$REGATE_EXEMPT_REGEX" || true)
        if [[ -z "$non_exempt" ]]; then
            log "#${QUEUE_NUM}: the ${behind} new commit(s) touch only non-compiled paths — no re-gate needed."
            gates_note="base moved (docs-only), not re-gated"
        else
            log "#${QUEUE_NUM}: gate: xcodebuild (rebased)…"
            if ! ( cd "$WT_DIR" && xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut \
                    -configuration Debug -derivedDataPath "${WT_DIR}/build/DerivedData" build ) \
                    </dev/null >/tmp/ws-implementer-rebuild.log 2>&1; then
                tail -30 /tmp/ws-implementer-rebuild.log
                warn "#${QUEUE_NUM}: GATE FAILED after rebase (xcodebuild) — leaving the window open and the branch alone."
                return
            fi
            log "#${QUEUE_NUM}: gate: test plan (rebased) — this kills the running app…"
            pkill -f "WhisperShortcut.app" 2>/dev/null || true; sleep 1
            if ! ( cd "$WT_DIR" && set -a && [[ -f .env ]] && . ./.env; set +a
                   xcodebuild test -project WhisperShortcut.xcodeproj -scheme WhisperShortcut-AppStore \
                     -testPlan WhisperShortcut-AppStore -destination 'platform=macOS' \
                     -skip-testing:WhisperShortcutTests/TranscriptionRoundtripTests \
                     -skip-testing:WhisperShortcutTests/LLMProviderRoundtripTests \
                     -derivedDataPath "${WT_DIR}/build/DerivedData-AppStore" ) \
                     </dev/null >/tmp/ws-implementer-retest.log 2>&1; then
                tail -40 /tmp/ws-implementer-retest.log
                warn "#${QUEUE_NUM}: GATE FAILED after rebase (test plan) — leaving the window open and the branch alone."
                return
            fi
            gates_note="re-gated on the new base"
            log "#${QUEUE_NUM}: gates green on the rebased branch."
        fi
    fi

    # After a clean rebase this is a fast-forward. --ff-only so we never quietly produce a merge
    # commit that nobody's gates ever saw.
    log "#${QUEUE_NUM}: window ran out and nobody stopped it — merging ${BRANCH} into main."
    local main_before; main_before=$(git -C "$REPO_ROOT" rev-parse main)
    if ! git -C "$REPO_ROOT" merge --ff-only "$BRANCH" >/dev/null 2>&1; then
        warn "#${QUEUE_NUM}: fast-forward merge failed — main moved again mid-run. The window stays open; the next tick retries."
        return
    fi

    # The branch already carries its own queue/ledger bookkeeping (Status=BRANCH/PR, Outcome
    # OPEN), so this only writes the outcome the merge just produced.
    set_queue_status "$QUEUE_NUM" "MERGED" || warn "queue write failed"
    set_ledger_outcome "$BRANCH" "MERGED"
    commit_bookkeeping "chore(implementer): close queue #${QUEUE_NUM} (${BRANCH}, ${gates_note})

Merged unattended: the ${DEADLINE:-} window ran out and nobody stopped it.
main is not a release — scripts/create-release.sh and the App Store submission
are still the operator's, and neither has run.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
    push_main

    git -C "$REPO_ROOT" worktree remove --force "$WT_DIR" >/dev/null 2>&1 || rm -rf "$WT_DIR"
    git -C "$REPO_ROOT" branch -D "$BRANCH" >/dev/null 2>&1
    [[ -n "$PR_URL" ]] && git -C "$REPO_ROOT" push -q origin --delete "$BRANCH" >/dev/null 2>&1
    rm -f "$file"

    local files note="/tmp/ws-merged-${QUEUE_NUM}.md"
    files=$(git -C "$REPO_ROOT" diff --name-only "$main_before" HEAD)
    {
        echo "VERDICT: queue #${QUEUE_NUM} is on main — merged unattended, ${gates_note}."
        echo
        echo "Nobody stopped the merge window${DEADLINE:+ (${DEADLINE})}, so it was carried out."
        echo "Branch ${BRANCH} and its worktree are gone."
        [[ -n "$PR_URL" ]] && echo "PR: ${PR_URL}"
        echo
        echo "## Not done, on purpose"
        echo
        echo "- The parent repo's submodule pointer still points at the old commit. Bumping it"
        echo "  says 'this is the app version I stand behind' and stays yours."
        echo "- No release. \`scripts/create-release.sh\` and the App Store submission are"
        echo "  untouched — main is not a release."
        echo
        echo "## Files"
        echo '```'
        echo "$files"
        echo '```'
        echo
        echo "Undo it:  git -C ${REPO_ROOT} revert --no-commit ${main_before}..HEAD"
    } >"$note"
    mail_out "WhisperShortcut implementer MERGED (#${QUEUE_NUM})" "$note"
    notify "WhisperShortcut implementer MERGED" "Queue #${QUEUE_NUM} is on main"
    rm -f "$note"
    log "═══ MERGED ═══  queue #${QUEUE_NUM} is on main (${gates_note})."
}

for window in "${WINDOWS[@]}"; do
    handle_window "$window"
done
