#!/usr/bin/env bash
# Self-test for worktree.sh: no Xcode, no app. Builds throwaway repos under mktemp.
#     bash scripts/lib/test-worktree.sh
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree.sh
source "$LIB_DIR/worktree.sh"
WORK="$(cd "$(mktemp -d /tmp/worktree-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
check() { if [[ "$2" == "$3" ]]; then echo "ok    $1 (=$3)"; else echo "FAIL  $1: expected '$2', got '$3'"; FAILED=1; fi; }
probe() { local out; out="$(worktree_main_root "$1")"; echo "$? ${out}"; }
G=(git -c user.email=t@t -c user.name=t -c init.defaultBranch=main)

mkdir "$WORK/repo" && cd "$WORK/repo" && "${G[@]}" init -q && "${G[@]}" commit -q --allow-empty -m init
check "main checkout"                   "1 " "$(probe "$WORK/repo")"
mkdir -p "$WORK/repo/.claude/worktrees"
"${G[@]}" worktree add -q "$WORK/repo/.claude/worktrees/a" -b a
check ".claude/worktrees linked"        "0 $WORK/repo" "$(probe "$WORK/repo/.claude/worktrees/a")"
mkdir -p "$WORK/.worktrees"
"${G[@]}" worktree add -q "$WORK/.worktrees/b" -b b
check "<parent>/.worktrees linked"      "0 $WORK/repo" "$(probe "$WORK/.worktrees/b")"
"${G[@]}" worktree add -q --detach "$WORK/repo/detached" HEAD
check "detached linked"                 "0 $WORK/repo" "$(probe "$WORK/repo/detached")"
check "outside any repo"                "1 " "$(probe "$WORK")"
# git cannot answer, legacy path layout still counts
mkdir -p "$WORK/plain/.claude/worktrees/x"
check "legacy path without git"         "0 $WORK/plain" "$(probe "$WORK/plain/.claude/worktrees/x")"

# submodule: main checkout and a linked worktree of it
"${G[@]}" init -q "$WORK/sub" && "${G[@]}" -C "$WORK/sub" commit -q --allow-empty -m init
"${G[@]}" -c protocol.file.allow=always submodule add -q "$WORK/sub" mod 2>/dev/null
check "submodule main checkout"         "1 " "$(probe "$WORK/repo/mod")"
"${G[@]}" -C "$WORK/repo/mod" worktree add -q "$WORK/.worktrees/m" -b m
check "submodule linked worktree"       "0 $WORK/repo/mod" "$(probe "$WORK/.worktrees/m")"
exit "$FAILED"
