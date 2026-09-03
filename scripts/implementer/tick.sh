#!/usr/bin/env bash
# The implementer's heartbeat — hourly under launchd.
#
# Architecture: plans/agent-loops.md. Ported from sabaki.dance's scripts/implementer/tick.sh,
# including the three failures that lane paid for and this one does not have to repeat again.
#
# Two steps, in this order, each skippable without blocking the next:
#   1. groom the queue  (groom-queue.py) — file loop proposals, promote ripe VETO rows
#   2. start the next build (run-implementer.sh) — takes the topmost BUILD/OPEN row
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

# --- Is the shared checkout usable? ----------------------------------------------------------
# Both steps write in the main checkout, so both need it on main and clean. This guard used to
# be Sabaki's worst blocker: it sat at the top and killed the whole tick, so 28 proposals piled
# up unread for eight days while the queue kept showing the same three hand-written rows. The
# fix there was per-step guards; the fix here is the same guard plus LOUD reporting, because a
# blocked lane that only whispers into a log file is indistinguishable from a quiet week.
BLOCK_STAMP="${TICK_LOG_DIR}/.blocked-since"
CURRENT_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    warn "main checkout is on '${CURRENT_BRANCH}' — the tick cannot groom or build until it is back on main."
    [[ -f "$BLOCK_STAMP" ]] || date +%s >"$BLOCK_STAMP"
    BLOCKED_HOURS=$(( ($(date +%s) - $(cat "$BLOCK_STAMP")) / 3600 ))
    # Report once a day, not once an hour — an alert that fires 24 times becomes noise, and
    # noise is how the eight-day blockage stayed invisible in the first place.
    #
    # Against a threshold, not `% 24 == 0`: this is a laptop, so ticks are skipped whenever the
    # lid is shut. A modulo test needs to land on the exact hour and would jump 23 → 25 over a
    # closed night — silently never reporting, which is the failure this whole block exists to
    # prevent. The last reported milestone is remembered instead.
    REPORTED_FILE="${BLOCK_STAMP}.reported"
    LAST_REPORTED=$(cat "$REPORTED_FILE" 2>/dev/null || echo 0)
    if (( BLOCKED_HOURS >= LAST_REPORTED + 24 )); then
        echo "$BLOCKED_HOURS" >"$REPORTED_FILE"
        NOTE=$(mktemp -t wstickblocked)
        {
            echo "VERDICT: implementer tick BLOCKED for ${BLOCKED_HOURS}h — checkout is on '${CURRENT_BRANCH}'."
            echo
            echo "Nothing has been groomed or built since then. Loop proposals are accumulating in"
            echo "\${IMPLEMENTER_INCOMING_DIR:-~/.local/state/whispershortcut-implementer/incoming}."
            echo "Fix: git -C ${REPO_ROOT} checkout main"
        } >"$NOTE"
        python3 "${REPO_ROOT}/scripts/send-report-mail.py" --to "${AUDIT_MAIL_TO:-mail@magnus-goedde.de}" \
            --subject "WhisperShortcut implementer tick BLOCKED (${BLOCKED_HOURS}h)" --body-file "$NOTE" \
            || osascript -e "display notification \"on branch ${CURRENT_BRANCH} for ${BLOCKED_HOURS}h\" with title \"Implementer tick blocked\"" >/dev/null 2>&1
        rm -f "$NOTE"
    fi
    exit 0
fi
rm -f "$BLOCK_STAMP" "${BLOCK_STAMP}.reported"

# --- Sync with origin first ------------------------------------------------------------------
# The groomer commits queue rows to the LOCAL main and, until 2026-09-03, nothing ever pushed
# them. Every merged PR then left local main diverged from origin — the first one did, within
# hours — and the operator's next `git pull` refused to fast-forward. So: rebase onto origin
# before writing, push after. Both are best-effort; the tick runs hourly, so a push that fails
# now (offline, lid just opened) simply lands on the next tick. Loud on failure, never fatal.
git -C "$REPO_ROOT" pull -q --rebase origin main \
    || warn "could not rebase main onto origin/main — grooming on a possibly stale main"

# --- 1. Groom --------------------------------------------------------------------------------
if [[ "${IMPLEMENTER_GROOM:-1}" == "1" ]]; then
    log "step 1: grooming the queue"
    python3 "${SCRIPT_DIR}/groom-queue.py" || warn "groom-queue.py exited non-zero — see above"
    # Only push what the groomer just wrote — the tree was clean and on main going in, so any
    # unpushed commit here is the queue bookkeeping and nothing else.
    if [[ -n "$(git -C "$REPO_ROOT" log --oneline origin/main..main 2>/dev/null)" ]]; then
        git -C "$REPO_ROOT" push -q origin main \
            && log "pushed queue bookkeeping to origin/main" \
            || warn "queue commit not pushed — will retry on the next tick"
    fi
else
    log "step 1: skipped (IMPLEMENTER_GROOM=0)"
fi

# --- 2. Build --------------------------------------------------------------------------------
# The runner does its own preflight (lock, monthly budget, scope, clean tree) and exits 0 with
# "nothing to do" when no BUILD/OPEN row exists, which is the common case. Let it decide.
log "step 2: starting the next build if one is due"
bash "${SCRIPT_DIR}/run-implementer.sh" || warn "run-implementer.sh exited non-zero — see above"

log "tick done"
