#!/usr/bin/env bash
# The implementer's heartbeat — hourly under launchd.
#
# Architecture: plans/agent-loops.md. Ported from sabaki.dance's scripts/implementer/tick.sh,
# including the three failures that lane paid for and this one does not have to repeat again.
#
# Two steps, and the difference between them is what this file is shaped around:
#   1. groom the queue  (groom-queue.py) — file loop proposals, promote ripe VETO rows.
#      Runs in a scratch worktree of its own and pushes to origin, so it does NOT care which
#      branch your checkout is on. Findings must never wait on your working state.
#   2. start the next build (run-implementer.sh) — takes the topmost BUILD/OPEN row. This one
#      genuinely needs the shared checkout on main, and is guarded there rather than globally.
#
# The tick never decides anything. Every build it starts was released either by you flagging a
# row BUILD, or by a veto window running out while you said nothing.
#
# Why hourly rather than one nightly run: the pipeline needs a Mac that is awake, and this one
# is a laptop. An hourly tick turns "the lid was shut" into LATER instead of NEVER.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Survives the re-exec below, where SCRIPT_DIR is /tmp and would compute nonsense.
REPO_ROOT="${IMPLEMENTER_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
[[ -n "${IMPLEMENTER_REPO_ROOT:-}" ]] && SCRIPT_DIR="${REPO_ROOT}/scripts/implementer"

# --- Run the version of ourselves that is on main --------------------------------------------
# launchd starts a path in the SHARED checkout, whose content is whatever branch somebody left
# it on. Sabaki spent 2026-08-28 running a months-old copy of this file while the fix for
# exactly that sat on main, unreachable — a loop that cannot rely on running its own current
# code cannot be trusted to improve itself. So pin to origin/main and re-exec when they differ.
if [[ -z "${IMPLEMENTER_TICK_REEXEC:-}" ]]; then
    PINNED="/tmp/whispershortcut-implementer-tick-main.sh"
    git -C "$REPO_ROOT" fetch -q origin main 2>/dev/null || true
    if git -C "$REPO_ROOT" show origin/main:scripts/implementer/tick.sh >"$PINNED" 2>/dev/null \
        && [[ -s "$PINNED" ]] && ! cmp -s "$PINNED" "${BASH_SOURCE[0]}" \
        && grep -q 'IMPLEMENTER_REPO_ROOT' "$PINNED"; then
        export IMPLEMENTER_TICK_REEXEC=1 IMPLEMENTER_REPO_ROOT="$REPO_ROOT"
        exec bash "$PINNED"
    fi
    rm -f "$PINNED"
fi

TICK_LOG_DIR="${REPO_ROOT}/build/logs/implementer"
mkdir -p "$TICK_LOG_DIR"
exec > >(tee -a "${TICK_LOG_DIR}/tick-$(date +%F).log") 2>&1

log()  { printf '[tick %s] %s\n' "$(date +%H:%M)" "$*"; }
warn() { printf '[tick %s] WARN: %s\n' "$(date +%H:%M)" "$*"; }

# --- PATH ------------------------------------------------------------------------------------
# launchd's `bash -lc` reads ~/.bash_profile, which does not exist here — the PATH additions
# live in ~/.zshrc and bash never sees them. So under launchd there is no ~/.local/bin, which
# is where cursor-agent AND claude live: the build agent and the review agent both. Sabaki's
# scheduled lane died on "cursor-agent not found" 87 times in a row while the binary sat
# installed and current the whole time. Prepend, so a stale copy on the system path cannot
# shadow the one actually maintained.
for extra in "${HOME}/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    [[ -d "$extra" ]] && case ":${PATH}:" in *":${extra}:"*) ;; *) export PATH="${extra}:${PATH}" ;; esac
done

CONFIG_FILE="${HOME}/.config/whispershortcut-implementer/env"
if [[ -f "$CONFIG_FILE" ]]; then
    set -a; # shellcheck disable=SC1090
    source "$CONFIG_FILE"; set +a
fi

# Two switches on purpose: IMPLEMENTER_ENABLED is the master kill switch shared with every
# other implementer script, IMPLEMENTER_TICK_ENABLED stops only the schedule. Both are read at
# run time — turning the automation off must never require an edit or a rebuild.
[[ "${IMPLEMENTER_ENABLED:-0}" == "1" ]]      || { log "IMPLEMENTER_ENABLED is not 1 — nothing to do."; exit 0; }
[[ "${IMPLEMENTER_TICK_ENABLED:-0}" == "1" ]] || { log "IMPLEMENTER_TICK_ENABLED is not 1 — schedule is off."; exit 0; }

# The runner refuses without these, but it refuses one at a time and only once a build starts.
# Name every missing one here, every hour: a lane that cannot build must not look idle.
for tool in cursor-agent claude gh; do
    command -v "$tool" >/dev/null 2>&1 || warn "${tool} is not on PATH — the build lane cannot complete until it is"
done

log "tick start (repo ${REPO_ROOT})"

# --- Only one tick at a time -----------------------------------------------------------------
# A groom that takes longer than the interval would otherwise meet the next tick inside the same
# worktree. mkdir is atomic and macOS ships no flock(1). The runner keeps its own separate lock.
TICK_LOCK="/tmp/whispershortcut-implementer-tick.lock.d"
if ! mkdir "$TICK_LOCK" 2>/dev/null; then
    log "another tick is still running (${TICK_LOCK}) — skipping this one."
    exit 0
fi
trap 'rmdir "$TICK_LOCK" 2>/dev/null' EXIT

git -C "$REPO_ROOT" fetch -q origin main || warn "could not fetch origin/main — working from what is on disk"

# --- 1. Groom — in its own worktree, whatever the shared checkout is doing --------------------
# Grooming only reads loop proposals and writes queue bookkeeping. It has no business depending
# on which branch you happen to be working on, and until 2026-09-03 it did: a tick that found
# the shared checkout on a feature branch groomed nothing, so proposals piled up unread. That is
# exactly how Sabaki lost eight days and 28 proposals. So the groomer gets a scratch worktree of
# its own, detached at origin/main, and pushes straight to origin — the shared checkout is never
# touched, which also removes the local-main divergence #53 had to repair.
GROOM_WT="${REPO_ROOT}/.claude/worktrees/implementer-groom"

# Every `git -C "$GROOM_WT"` below is only safe once this returns 0. Verified on 2026-09-03 by
# getting it wrong: an earlier version checked whether the worktree had FILES, which it did, and
# went ahead — but git's own idea of the working directory still pointed at the module gitdir, so
# `reset --hard` checked a full source tree out into `.git/modules/whisper-shortcut/`. Nothing
# was corrupted, but that is the failure mode to design against: with a wrong `core.worktree`,
# every write lands somewhere nobody is looking.
groom_worktree_is_sane() {
    [[ "$(git -C "$GROOM_WT" rev-parse --show-toplevel 2>/dev/null)" == "$GROOM_WT" ]]
}

ensure_groom_worktree() {
    if [[ ! -e "${GROOM_WT}/.git" ]]; then
        rm -rf "$GROOM_WT"
        git -C "$REPO_ROOT" worktree prune
        git -C "$REPO_ROOT" worktree add -q --detach "$GROOM_WT" origin/main || return 1
    fi

    # This repo is a git submodule, and the shared module config sets `core.worktree`, which
    # overrides every linked worktree. `git worktree add` writes the files anyway, so the
    # directory LOOKS right while every later git command operates on the wrong tree. The
    # per-worktree `config.worktree` file is the fix; `extensions.worktreeConfig` is already on.
    if ! groom_worktree_is_sane; then
        local gitdir
        gitdir=$(sed -n 's/^gitdir: //p' "${GROOM_WT}/.git" 2>/dev/null)
        if [[ -z "$gitdir" || ! -d "$gitdir" ]]; then
            warn "groom worktree has no resolvable gitdir — refusing to touch it"
            return 1
        fi
        printf '[core]\n\tworktree = %s\n' "$GROOM_WT" >"${gitdir}/config.worktree"
        log "repaired the groom worktree's core.worktree (submodule quirk)"
    fi
    # Re-checked, not assumed: if the repair did not take, every command below would write into
    # the gitdir. Stop instead — a tick that grooms nothing is recoverable, this is not.
    if ! groom_worktree_is_sane; then
        warn "groom worktree still resolves to $(git -C "$GROOM_WT" rev-parse --show-toplevel 2>/dev/null) — refusing to run git in it"
        return 1
    fi

    # Unpushed commits from an earlier tick are REBASED, never reset away. The groomer archives a
    # proposal file the moment it files the row, so discarding the commit would lose the finding
    # for good — the one irreversible thing in this whole lane.
    if [[ -n "$(git -C "$GROOM_WT" log --oneline origin/main..HEAD 2>/dev/null)" ]]; then
        warn "groom worktree carries unpushed commits from an earlier tick — rebasing, not resetting"
        git -C "$GROOM_WT" rebase -q origin/main || {
            git -C "$GROOM_WT" rebase --abort 2>/dev/null
            warn "rebase failed — leaving the worktree as it is so nothing is lost; fix it by hand at ${GROOM_WT}"
            return 1
        }
    else
        git -C "$GROOM_WT" reset -q --hard origin/main || return 1
    fi
}

if [[ "${IMPLEMENTER_GROOM:-1}" == "1" ]]; then
    log "step 1: grooming the queue (worktree ${GROOM_WT})"
    if ensure_groom_worktree; then
        # The copy IN the worktree, so every path it derives lands there and not in your checkout.
        python3 "${GROOM_WT}/scripts/implementer/groom-queue.py" \
            || warn "groom-queue.py exited non-zero — see above"
        if [[ -n "$(git -C "$GROOM_WT" log --oneline origin/main..HEAD 2>/dev/null)" ]]; then
            if git -C "$GROOM_WT" push -q origin HEAD:main; then
                log "pushed queue bookkeeping to origin/main"
            else
                # Most likely origin moved while we groomed. One rebase-and-retry; if that fails
                # the commit stays in the worktree and the next tick picks it up above.
                warn "push rejected — rebasing on the current origin/main and retrying once"
                if git -C "$GROOM_WT" pull -q --rebase origin main \
                    && git -C "$GROOM_WT" push -q origin HEAD:main; then
                    log "pushed queue bookkeeping to origin/main (after rebase)"
                else
                    warn "queue commit still unpushed — kept in the worktree, retried next tick"
                fi
            fi
        fi
    else
        warn "could not prepare the groom worktree — nothing groomed this tick"
    fi
else
    log "step 1: skipped (IMPLEMENTER_GROOM=0)"
fi

# --- 2. Build — this one really does need the shared checkout ---------------------------------
# The runner builds in a worktree it creates from the shared checkout's `main`, so unlike
# grooming it cannot proceed while you are on a feature branch. Guarding it here rather than at
# the top is the whole point of this restructure: a busy checkout now costs you builds, not
# findings.
BLOCK_STAMP="${TICK_LOG_DIR}/.blocked-since"
REPORTED_FILE="${BLOCK_STAMP}.reported"
CURRENT_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    warn "step 2 skipped: shared checkout is on '${CURRENT_BRANCH}'. Grooming ran; builds wait for main."
    [[ -f "$BLOCK_STAMP" ]] || date +%s >"$BLOCK_STAMP"
    BLOCKED_HOURS=$(( ($(date +%s) - $(cat "$BLOCK_STAMP")) / 3600 ))
    # Report once a day, not once an hour — an alert that fires 24 times becomes noise, and
    # noise is how the eight-day blockage stayed invisible in the first place.
    #
    # Against a threshold, not `% 24 == 0`: this is a laptop, so ticks are skipped whenever the
    # lid is shut. A modulo test needs to land on the exact hour and would step straight over it
    # across a closed night — silently never reporting, which is the failure this exists to
    # prevent. The last reported milestone is remembered instead.
    LAST_REPORTED=$(cat "$REPORTED_FILE" 2>/dev/null || echo 0)
    if (( BLOCKED_HOURS >= LAST_REPORTED + 24 )); then
        echo "$BLOCKED_HOURS" >"$REPORTED_FILE"
        NOTE=$(mktemp -t wstickblocked)
        {
            echo "VERDICT: implementer builds paused ${BLOCKED_HOURS}h — checkout is on '${CURRENT_BRANCH}'."
            echo
            echo "Grooming is unaffected and has kept running: proposals are still being filed and"
            echo "veto windows still promote. What is waiting is the build lane."
            echo "Released rows sit in plans/implementer-queue.md until then."
            echo "Fix: git -C ${REPO_ROOT} checkout main"
        } >"$NOTE"
        python3 "${REPO_ROOT}/scripts/send-report-mail.py" --to "${AUDIT_MAIL_TO:-mail@magnus-goedde.de}" \
            --subject "WhisperShortcut implementer builds paused (${BLOCKED_HOURS}h)" --body-file "$NOTE" \
            || osascript -e "display notification \"on branch ${CURRENT_BRANCH} for ${BLOCKED_HOURS}h\" with title \"Implementer builds paused\"" >/dev/null 2>&1
        rm -f "$NOTE"
    fi
    log "tick done (groom only)"
    exit 0
fi
rm -f "$BLOCK_STAMP" "$REPORTED_FILE"

# Fast-forward only: the groomer no longer commits here, so local main has nothing of its own to
# preserve, and anything that would need a merge is yours and not mine to resolve.
git -C "$REPO_ROOT" merge -q --ff-only origin/main 2>/dev/null \
    || warn "shared main could not be fast-forwarded to origin/main — the build may use a stale base"

# The runner does its own preflight (lock, monthly budget, scope, clean tree) and exits 0 with
# "nothing to do" when no BUILD/OPEN row exists, which is the common case. Let it decide.
log "step 2: starting the next build if one is due"
bash "${SCRIPT_DIR}/run-implementer.sh" || warn "run-implementer.sh exited non-zero — see above"

log "tick done"
