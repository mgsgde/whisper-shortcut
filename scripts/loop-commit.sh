#!/usr/bin/env bash
# Commits a scheduled loop's own output — its ledger rows and its digest — so "delivered" means
# "committed". One file, four callers, same shape as scripts/loop-prompt.sh and for the same
# reason: a commit rule that lives in four job scripts drifts in four directions.
#
#     bash scripts/loop-commit.sh --repo <path> --message "<msg>" -- <path> [<path>…]
#
# Why this exists (loop-ledger L10, 2026-09-19): usage-review runs 4–5 appended rows to
# plans/improvement-ledger.md and plans/instrumentation-gaps.md and nothing committed them. The
# groomer reads origin/main, saw no OPEN gap row, and filed two instrumentation proposals as ASK
# instead of BUILD; the parent repo's business/*-reviews/ sat untracked for weeks. A row that
# exists only in a working copy is one `git checkout -- plans/` from not existing at all.
#
# Behaviour, in the order it happens:
#   - Paths are relative to --repo and must be explicit: `.` and anything with a glob character
#     is refused (exit 2). The helper never touches a path it was not given — AGENTS.md rule 2.
#   - If the repo is not on `main`, it commits nothing (WARN, exit 0). The checkout belongs to
#     whoever is at the keyboard (AGENTS.md rule 4); tick.sh already mails about a non-main
#     checkout. Uncommitted output is not lost, only late — the next run on main picks it up.
#   - Missing paths are skipped with a WARN. Nothing staged → "nothing to commit", exit 0.
#   - Commit, then `pull --rebase origin main` and `push origin main`. Never --autostash, never
#     --force: a dirty tree makes the rebase refuse, and that is the intended behaviour, not a
#     bug to work around. Every failure past the commit is a WARN that leaves the commit on local
#     main — the next run's pull --rebase carries it (the same contract as tick.sh's queue
#     bookkeeping). A rebase that stops on a conflict is aborted; the commit stays local.
#
# No Co-Authored-By trailer: the job, not a chat, is the author. bash 3.2 (macOS /bin/bash).
set -euo pipefail

REPO=""
MESSAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) shift; REPO="${1:-}" ;;
    --message) shift; MESSAGE="${1:-}" ;;
    --) shift; break ;;
    -h|--help)
      echo "usage: loop-commit.sh --repo <path> --message <msg> -- <path> [<path>…]"; exit 0 ;;
    *) echo "loop-commit.sh: unknown argument '$1' (usage: --repo <path> --message <msg> -- <path>…)" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$REPO" ]    || { echo "loop-commit.sh: --repo is required" >&2; exit 2; }
[ -n "$MESSAGE" ] || { echo "loop-commit.sh: --message is required" >&2; exit 2; }
[ $# -gt 0 ]      || { echo "loop-commit.sh: no paths given after --" >&2; exit 2; }
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "loop-commit.sh: $REPO is not a git work tree" >&2; exit 2; }

# Explicit paths only. `.` (and `..`, and an empty string) would sweep whatever anyone else left in
# the tree — the exact thing rule 2 forbids — and a glob is a path the caller has not looked at.
for p in "$@"; do
  case "$p" in
    ''|.|..|./|../)
      echo "loop-commit.sh: refusing path '$p' — name each file explicitly (never '.')" >&2; exit 2 ;;
    *'*'*|*'?'*|*'['*)
      echo "loop-commit.sh: refusing path '$p' — no globs, name each file explicitly" >&2; exit 2 ;;
  esac
done

BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
if [ "$BRANCH" != "main" ]; then
  echo "WARN: loop-commit.sh: $REPO is on '$BRANCH', not main — committing nothing this run (the output stays in the working copy and is picked up by a run that finds main)."
  exit 0
fi

for p in "$@"; do
  if [ -e "$REPO/$p" ] || git -C "$REPO" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    git -C "$REPO" add -- "$p"
  else
    echo "WARN: loop-commit.sh: path '$p' does not exist in $REPO — skipped."
  fi
done

if git -C "$REPO" diff --cached --quiet; then
  echo "loop-commit.sh: nothing to commit in $REPO."
  exit 0
fi

git -C "$REPO" commit -q -m "$MESSAGE"
SHA="$(git -C "$REPO" rev-parse --short HEAD)"
echo "loop-commit.sh: committed $SHA on main in $REPO — $MESSAGE"

# From here on nothing may fail the caller: the commit exists, and every step below only decides
# whether it also reaches origin now or on the next run.
if ! git -C "$REPO" pull -q --rebase origin main; then
  git -C "$REPO" rebase --abort >/dev/null 2>&1 || true
  echo "WARN: loop-commit.sh: pull --rebase origin main failed in $REPO (dirty tree or conflict) — $SHA stays on local main; the next run's rebase carries it."
  exit 0
fi
if git -C "$REPO" push -q origin main; then
  echo "loop-commit.sh: pushed main to origin ($REPO)."
else
  echo "WARN: loop-commit.sh: push origin main failed in $REPO — $SHA stays on local main; the next run retries."
fi
exit 0
