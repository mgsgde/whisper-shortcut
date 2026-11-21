# Merge train

A finished PR with green CI should not wait for someone to click merge. Dependabot PRs sat open
for a week. The merge train is a plain bash script under launchd (every 20 minutes) that merges
open, non-draft PRs against `main` on GitHub once their CI is green, unless the PR is opted out.
Each tick drains the queue: every green, mergeable PR is merged, also when it is behind `main`. The
train never updates branches. Two green PRs that clash semantically are caught by CI on `main`
(`ci.yml` runs on push), a main-CI brake pauses the train while main is red, and the Dev app only
installs green main commits.

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

Main-CI brake first: the newest completed `CI` push run on `main` is looked up. If it failed,
was cancelled or timed out, nothing is merged this tick; the run is recorded as `blocked main-red
<sha>`, a notification fires and ONE mail goes out per red sha (the commits since the last green
run are listed; the mailed sha is kept in `$STATE/main-red-mailed`). No push run yet, or `gh`
failing, does not block.

Then candidates are walked in ascending PR number. There is no limit per tick.

1. Mergeability not computed yet: skip, try next tick.
2. Merge conflict with main: stop on that PR (see failure handling).
3. CI red (any failed, cancelled, timed-out or errored check): stop on that PR.
4. CI pending, or not started: skip, move on to the next PR.
5. CI green and mergeable: `gh pr merge --merge --match-head-commit <sha> --delete-branch`, comment
   the merge commit, continue with the next PR. Behind main does not matter. If the merge fails
   (for example the PR started to conflict after an earlier merge in the same tick), stop on that PR.

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
local checkout. Releases are cut by `scripts/release-nightly-job.sh`. Closing a stale PR does not
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

## Runner outages

When GitHub has no hosted runners, jobs get cancelled with the annotation "The job was not
acquired by Runner of type hosted even after multiple attempts" and the run turns `failure`.
`runner_outage.py` recognises that (every cancelled job carries a `was not acquired by Runner`
annotation, no job really failed). The train then re-runs the failed jobs instead of braking main
or failing the PR, at most twice per run (`MERGE_TRAIN_MAX_RERUNS`); after that it counts red as
before. A PR whose only red checks are cancelled shows as pending in `stale-prs.sh`.
