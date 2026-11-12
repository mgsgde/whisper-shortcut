#!/bin/bash
# Is this checkout a linked git worktree, and where is the main checkout?
# Sourced by scripts/rebuild-and-restart.sh; self-test: bash scripts/lib/test-worktree.sh

# worktree_main_root <project dir>
#   Linked worktree: prints the main checkout's work tree and returns 0.
#   Main checkout (or not a git checkout): prints nothing and returns 1.
# Git is asked first, because worktrees live in several places (`.claude/worktrees/<n>`,
# `<parent>/.worktrees/<n>`, a detached `build/dev-daily/src`): a linked worktree's git dir
# differs from the common git dir, the main checkout's does not. The old `.claude/worktrees/`
# path match stays as a fallback for when git cannot answer.
worktree_main_root() {
  local dir="$1" legacy="${1%%/.claude/worktrees/*}" gitdir common wt root=""
  gitdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" && gitdir="$(cd "$gitdir" 2>/dev/null && pwd -P)"
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && common="$(cd "$common" 2>/dev/null && pwd -P)"
  if [[ -n "$gitdir" && -n "$common" ]]; then
    [[ "$gitdir" != "$common" ]] || return 1
    # In a submodule the common git dir is .git/modules/<n>; core.worktree (relative to it) names
    # the work tree. A plain repo: the first entry of `git worktree list`.
    wt="$(git --git-dir="$common" config --get core.worktree 2>/dev/null || true)"
    if [[ -n "$wt" ]]; then
      root="$(cd "$common" && cd "$wt" 2>/dev/null && pwd)"
    else
      root="$(git -C "$dir" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
    fi
    [[ -n "$legacy" && "$legacy" != "$dir" ]] && root="$legacy"
    printf '%s\n' "${root:-$dir}"
    return 0
  fi
  if [[ "$legacy" != "$dir" ]]; then printf '%s\n' "$legacy"; return 0; fi
  return 1
}
