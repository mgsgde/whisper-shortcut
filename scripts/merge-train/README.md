# Merge train

A finished PR with green CI should not wait for someone to click merge. Dependabot PRs sat open
for a week. The merge train is a plain bash script under launchd (every 20 minutes) that merges
open PRs labelled `merge-train` into `main` on GitHub once their CI is green.

## What qualifies

- Any open, non-draft PR against `main` with the `merge-train` label.
- Dependabot adds the label itself (`.github/dependabot.yml`).
- Implementer or session PRs: `bash scripts/merge-train/train.sh --add <pr>`.
- Implementer PRs keep their own merge-window flow (`scripts/implementer/release-merges.sh`).
  Label one only if you want it merged without the window.

## The rules, per tick

Candidates are walked in ascending PR number. At most one merge (or branch update) per tick, so
the commit that gets merged is the commit CI tested.

1. Mergeability not computed yet: skip, try next tick.
2. Merge conflict with main: stop on that PR (see failure handling).
3. CI red (any failed, cancelled, timed-out or errored check): stop on that PR.
4. CI pending, or not started: skip, move on to the next PR.
5. CI green but behind main: update the branch with a merge commit, end the tick. CI re-runs and
   the PR merges on a later tick. If the update conflicts, stop on that PR.
6. CI green and up to date: `gh pr merge --merge --match-head-commit <sha> --delete-branch`, comment
   the merge commit, end the tick.

## What it never does

Tag, release, submit to the App Store, touch the parent repo's submodule pointer, or touch any
local checkout. Releases stay manual (`scripts/create-release.sh`).

## Failure handling

On a stop, the PR gets the `merge-train-failed` label and a comment with the reason, and a macOS
notification fires. The train ignores it from then on. Fix the problem, remove
`merge-train-failed`, and it is back on the train.

## Operating it

```bash
bash scripts/merge-train/install.sh            # once; refuses until train.sh is on origin/main
bash scripts/merge-train/install.sh --remove
bash scripts/merge-train/train.sh --dry-run    # reads and decides, changes nothing
touch ~/.local/state/whispershortcut-merge-train/PAUSED   # pause; rm to resume
```

State dir (`$MERGE_TRAIN_STATE`, default `~/.local/state/whispershortcut-merge-train`):
`launchd.log`, `runs.tsv` (time, action, PR, detail; one row per run) and the run lock.
