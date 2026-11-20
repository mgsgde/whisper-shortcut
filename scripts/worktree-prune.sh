#!/usr/bin/env bash
# Prune finished git worktrees.
#
#     bash scripts/worktree-prune.sh           # dry-run: one line per worktree, KEEP or REMOVE + reason
#     bash scripts/worktree-prune.sh --apply   # remove each REMOVE via scripts/worktree-remove.sh, then `git worktree prune`
#
# A worktree is removable only when it has no uncommitted/untracked changes, no running process has
# its cwd in it, it was not touched in the last 2 h, AND its work is on origin/main: a branch with a
# merged PR, a branch gone on origin whose HEAD is strictly behind origin/main, or a detached HEAD
# strictly behind origin/main and idle for 24 h. Plain ancestry alone is never enough. The main checkout and anything under build/ (dev-daily, release jobs)
# are always kept. Branches are never deleted.
set -uo pipefail

APPLY=0
case "${1:-}" in
    --apply) APPLY=1 ;;
    "") ;;
    *) echo "usage: worktree-prune.sh [--apply]" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git -C "$HERE" fetch -q origin 2>/dev/null || echo "WARN: git fetch origin failed; using stale refs" >&2

# First `worktree` entry is the main checkout (in a submodule: the same via core.worktree).
LIST="$(git -C "$HERE" worktree list --porcelain)"
FIRST="$(awk '/^worktree /{sub(/^worktree /,""); print; exit}' <<<"$LIST")"
_common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
_wt="$(git --git-dir="$_common" config --get core.worktree 2>/dev/null || true)"
MAIN="$FIRST"
[[ -n "$_wt" ]] && MAIN="$(cd "$_common" && cd "$_wt" && pwd -P)"
MAIN_P="$(cd "$MAIN" 2>/dev/null && pwd -P || echo "$MAIN")"

GH_REPO="$(cd "$HERE" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -n "$GH_REPO" ]] || GH_REPO="mgsgde/whisper-shortcut"
ORIGIN_TIP="$(git -C "$HERE" rev-parse origin/main 2>/dev/null || true)"

# Working directories of running processes: a worktree one of them sits in is in use.
CWDS="$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u)"
in_use() {  # path -> 0 when some process has its cwd in the path or below
    local p="$1" c
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        [[ "$c" == "$p" || "$c" == "$p"/* ]] && return 0
    done <<<"$CWDS"
    return 1
}

# Newest mtime (epoch) of the worktree's index / HEAD / .git file.
wt_mtime() {
    local wt="$1" gd f m best=0
    gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { echo 0; return; }
    for f in "$gd/index" "$gd/HEAD" "$wt/.git"; do
        m="$(stat -f %m "$f" 2>/dev/null || echo 0)"
        (( m > best )) && best="$m"
    done
    echo "$best"
}

decide() {  # path branch head -> prints "KEEP reason" or "REMOVE reason"
    local wt="$1" branch="$2" head="$3" dirty mt age
    local wt_p; wt_p="$(cd "$wt" 2>/dev/null && pwd -P || echo "$wt")"
    [[ "$wt_p" == "$MAIN_P" || "$wt" == "$FIRST" ]] && { echo "KEEP main checkout"; return; }
    [[ "$wt_p" == "$MAIN_P"/build/* || "$wt_p" == */build/* ]] && { echo "KEEP under build/ (dev-daily / release job)"; return; }
    [[ -d "$wt" ]] || { echo "REMOVE directory missing (stale registration)"; return; }
    if in_use "$wt_p" || in_use "$wt"; then echo "KEEP a running process has its cwd here"; return; fi
    dirty="$(git -C "$wt" status --porcelain 2>/dev/null)"
    [[ -z "$dirty" ]] || { echo "KEEP uncommitted or untracked changes ($(wc -l <<<"$dirty" | tr -d ' ') entries)"; return; }
    mt="$(wt_mtime "$wt")"; age=$(( $(date +%s) - mt ))
    if (( age < 7200 )); then echo "KEEP modified $((age / 60)) min ago (< 2 h)"; return; fi
    if [[ -z "$branch" ]]; then
        if [[ "$head" == "$ORIGIN_TIP" ]]; then echo "KEEP detached HEAD ${head:0:8} is the origin/main tip"; return; fi
        if ! git -C "$HERE" merge-base --is-ancestor "$head" origin/main 2>/dev/null; then
            echo "KEEP detached HEAD ${head:0:8} not on origin/main"; return
        fi
        if (( age < 86400 )); then echo "KEEP detached HEAD ${head:0:8} on origin/main but modified $((age / 3600)) h ago (< 24 h)"; return; fi
        echo "REMOVE detached HEAD ${head:0:8} is an ancestor of origin/main and idle for $((age / 3600)) h"
        return
    fi
    if [[ -n "$(gh pr list -R "$GH_REPO" --state merged --head "$branch" --limit 1 --json number -q '.[].number' 2>/dev/null)" ]]; then
        echo "REMOVE branch $branch has a merged PR"; return
    fi
    if [[ -z "$(git -C "$HERE" ls-remote --heads origin "$branch" 2>/dev/null)" ]]; then
        if [[ "$head" != "$ORIGIN_TIP" ]] && git -C "$HERE" merge-base --is-ancestor "$head" origin/main 2>/dev/null; then
            echo "REMOVE branch $branch gone on origin and its HEAD is on origin/main"; return
        fi
        echo "KEEP branch $branch gone on origin, no merged PR and HEAD not (strictly) on origin/main (unpushed work?)"; return
    fi
    echo "KEEP branch $branch still on origin, no merged PR"
}

removed=0
while IFS="|" read -r wt branch head; do
    [[ -n "$wt" ]] || continue
    verdict="$(decide "$wt" "$branch" "$head")"
    echo "${verdict%% *} ${wt} — ${verdict#* }"
    if [[ "$APPLY" == "1" && "$verdict" == REMOVE* ]]; then
        if [[ ! -d "$wt" ]]; then removed=$((removed+1)); continue; fi
        if bash "$HERE/worktree-remove.sh" "$wt"; then removed=$((removed+1)); else echo "  could not remove $wt (see above), continuing" >&2; fi
    fi
done < <(awk -v RS= -F'\n' '{
    wt=""; br=""; hd=""; bare=0;
    for (i=1;i<=NF;i++) {
        if ($i ~ /^worktree /) wt=substr($i,10);
        else if ($i == "bare") bare=1;
        else if ($i ~ /^HEAD /) hd=substr($i,6);
        else if ($i ~ /^branch /) { br=substr($i,8); sub(/^refs\/heads\//,"",br) }
    }
    if (bare == 0) print wt "|" br "|" hd
}' <<<"$LIST")

if [[ "$APPLY" == "1" ]]; then
    git -C "$HERE" worktree prune
    echo "removed: $removed"
fi
exit 0
