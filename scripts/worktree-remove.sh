#!/usr/bin/env bash
# Remove a git worktree — but never from under a running WhisperShortcut.
#
#     bash scripts/worktree-remove.sh <worktree-path>                  # refuse if the app runs from it
#     bash scripts/worktree-remove.sh --relaunch-main <worktree-path>  # quit it, relaunch the main build, remove
#
# Why this exists (queue #10, 2026-09-16): `scripts/rebuild-and-restart.sh` launches the app from
# `<checkout>/build/DerivedData/…`, so an app started inside a worktree keeps running after
# `git worktree remove --force` deletes its binary. macOS TCC then cannot resolve the process
# path (`tccd: proc_pidpath_audittoken() failed`), coreaudiod denies the input device, and
# every dictation records -120 dB silence until the app is relaunched from a checkout that still
# exists. The user sees "recording was silent" with no hint why.
#
# Without --relaunch-main this script only refuses and prints the way out; with it, it quits the
# processes that run from the worktree, relaunches the MAIN checkout's build (never the
# worktree's), and then removes. It only ever touches processes that run from the worktree being
# removed — an app running from the main checkout is left alone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# When invoked from inside a worktree, the main checkout is the part before /.claude/worktrees/.
MAIN_ROOT="${REPO_ROOT%%/.claude/worktrees/*}"
MAIN_APP="${MAIN_ROOT}/build/DerivedData/Build/Products/Debug/WhisperShortcut.app"

RELAUNCH=0
WT=""
for arg in "$@"; do
    case "$arg" in
        --relaunch-main) RELAUNCH=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) echo "worktree-remove: unknown flag $arg" >&2; exit 2 ;;
        *) WT="$arg" ;;
    esac
done
[[ -n "$WT" ]] || { echo "usage: worktree-remove.sh [--relaunch-main] <worktree-path>" >&2; exit 2; }
[[ -e "$WT" ]] || { echo "worktree-remove: no such path: $WT" >&2; exit 2; }
WT="$(cd "$WT" && pwd -P)"
[[ "$WT" != "$MAIN_ROOT" && "$WT" != "$(cd "$MAIN_ROOT" && pwd -P)" ]] \
    || { echo "worktree-remove: $WT is the main checkout, not a worktree" >&2; exit 2; }

# Anything whose command line lives under the worktree's DerivedData: the app (direct or
# App Store variant), or an xcodebuild still writing there. Neither survives an rm -rf.
live_pids() { pgrep -f "${WT}/build/DerivedData" 2>/dev/null || true; }

PIDS=$(live_pids)
if [[ -n "$PIDS" ]]; then
    echo "⚠️  Still running from ${WT}:"
    ps -o pid=,command= -p $(echo "$PIDS" | tr '\n' ',' | sed 's/,$//') | sed 's/^/    /' || true
    if [[ "$RELAUNCH" != "1" ]]; then
        echo
        echo "Removing the worktree now would delete this app's binary under it. macOS then denies"
        echo "it the microphone (tccd cannot resolve the process path) and every dictation records"
        echo "silence until you relaunch. Not removing."
        echo
        echo "Either relaunch the main checkout's build first:"
        echo "    open '${MAIN_APP}'"
        echo "or let this script do that for you:"
        echo "    bash '${MAIN_ROOT}/scripts/worktree-remove.sh' --relaunch-main '${WT}'"
        exit 1
    fi
    echo "→ quitting them and relaunching the main checkout's build"
    kill $PIDS 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        sleep 1
        [[ -z "$(live_pids)" ]] && break
    done
    PIDS=$(live_pids)
    if [[ -n "$PIDS" ]]; then
        echo "  • did not quit within 5s — SIGKILL → $(echo "$PIDS" | tr '\n' ' ')"
        kill -9 $PIDS 2>/dev/null || true
        sleep 1
    fi
    if [[ -d "$MAIN_APP" ]]; then
        open "$MAIN_APP" || echo "⚠️  could not relaunch ${MAIN_APP} — start it yourself"
    else
        echo "⚠️  no main-checkout build at ${MAIN_APP} — run scripts/rebuild-and-restart.sh from ${MAIN_ROOT}"
    fi
fi

if ! git -C "$MAIN_ROOT" worktree remove --force "$WT" 2>/dev/null; then
    # Not registered any more (already pruned) but the directory lingers. Only sweep it when it
    # sits where worktrees belong — never rm -rf an arbitrary path.
    case "$WT" in
        "$(cd "$MAIN_ROOT" && pwd -P)"/.claude/worktrees/*) rm -rf "$WT" ;;
        *) echo "worktree-remove: git refused to remove $WT and it is not under .claude/worktrees/ — leaving it" >&2; exit 1 ;;
    esac
fi
git -C "$MAIN_ROOT" worktree prune 2>/dev/null || true
echo "removed ${WT}"
