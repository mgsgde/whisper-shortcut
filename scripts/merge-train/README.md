# Merge train

A finished PR with green CI should not wait for someone to click merge. Dependabot PRs sat open
for a week. The merge train is a plain bash script under launchd (every 20 minutes) that merges
open, non-draft PRs against `main` on GitHub once their CI is green, unless the PR is opted out.

## What qualifies

Trusted (no label needed): the repo owner — the owner part of the GitHub repo, e.g. `mgsgde` in
`mgsgde/whisper-shortcut` — and Dependabot (`app/dependabot`, or `dependabot[bot]`).

Skipped silently, and never failed:

- label `hold` — never merge this PR automatically
- label `needs-device-test` — waiting on a manual test on a device
- label `merge-train-failed` — the train already stopped on it (see failure handling)
- drafts
- a branch whose name starts with `implementer/` (its own merge window,
  `scripts/implementer/release-merges.sh`)
- any other author

An `implementer/` branch or an external author joins the train only with an explicit
`merge-train` label: `bash scripts/merge-train/train.sh --add <pr>`. That label does not
override `hold`, `needs-device-test`, `merge-train-failed`, or a draft.

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

## Weekly list of old PRs

Mondays at 08:30, `stale-prs.sh` (same `install.sh`, same state dir) looks at every open PR
against `main`, drafts included. Age is whole days since the PR was opened.

Three days or older: one mail line, oldest first. The reason is the first match: device test
(`needs-device-test`), `hold`, the train stopped (`merge-train-failed`, from its comment),
draft, merge conflict, red CI, CI running or not started, external author without `merge-train`,
an `implementer/` branch, or green and waiting for the train.

Fourteen days or older: the PR is closed and the branch is kept. Those lines sit in their own
block at the top of the mail. No mail when nothing is three days old. The mail goes to
`$AUDIT_MAIL_TO` (default `mail@magnus-goedde.de`; `~/.config/whispershortcut-implementer/env`
is read when it exists) and a notification fires with the same subject.

```bash
bash scripts/merge-train/stale-prs.sh --dry-run   # print the mail; close nothing, send nothing
```

## What it never does

Tag, release, submit to the App Store, touch the parent repo's submodule pointer, or touch any
local checkout. Releases stay manual (`scripts/create-release.sh`). Closing a stale PR does not
delete its branch.

## Failure handling

On a stop, the PR gets the `merge-train-failed` label and a comment with the reason, and a macOS
notification fires. The train ignores it from then on. Fix the problem, remove
`merge-train-failed`, and a PR the train is allowed to merge is back on the next tick.

## Operating it

```bash
bash scripts/merge-train/install.sh            # once; refuses until train.sh and stale-prs.sh are on origin/main
bash scripts/merge-train/install.sh --remove
bash scripts/merge-train/train.sh --dry-run    # reads and decides, changes nothing
bash scripts/merge-train/stale-prs.sh --dry-run
touch ~/.local/state/whispershortcut-merge-train/PAUSED   # pause the train; the Monday list still runs
```

State dir (`$MERGE_TRAIN_STATE`, default `~/.local/state/whispershortcut-merge-train`):
`launchd.log`, `runs.tsv` (time, action, PR, detail; one row per train run), `stale-launchd.log`,
`stale-runs.tsv` (time, listed, closed; listed includes the closed ones) and the run lock.
