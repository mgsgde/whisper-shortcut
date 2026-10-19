#!/usr/bin/env bash
# The merge train — every 20 minutes under launchd.
#
# Why: a finished PR with green CI should not wait for somebody to click merge. Dependabot PRs
# sat open for a week; implementer and session PRs wait the same way. Ported from a sibling
# project's merge train; see scripts/merge-train/README.md.
#
# What it does: takes open PRs against main that carry the `merge-train` label and merges at
# most ONE per tick, once its CI is green and the branch is up to date with main. Serial on
# purpose: the commit that gets merged is then exactly the commit CI tested.
#
# What it never does: tag, release, touch the parent repo's submodule pointer, or touch any
# local checkout. Merging happens GitHub-side through gh, so no local git state matters.
# Releases stay manual (scripts/create-release.sh).
#
#     train.sh [--dry-run]     read everything, decide, print what it would do, change nothing
#     train.sh --add <pr>      put a PR on the train (adds the label)
#
# Pause: touch $STATE/PAUSED  (state dir default ~/.local/state/whispershortcut-merge-train)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Survives the plist's re-exec of the origin/main copy, where SCRIPT_DIR is /tmp.
REPO_ROOT="${MERGE_TRAIN_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# launchd's `bash -lc` has no ~/.local/bin or Homebrew on PATH (the additions live in ~/.zshrc).
for extra in "${HOME}/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    [[ -d "$extra" ]] && case ":${PATH}:" in *":${extra}:"*) ;; *) export PATH="${extra}:${PATH}" ;; esac
done

STATE="${MERGE_TRAIN_STATE:-${HOME}/.local/state/whispershortcut-merge-train}"
LABEL="${MERGE_TRAIN_LABEL:-merge-train}"   # override exists only to test the decision logic
FAILED_LABEL="merge-train-failed"
DRY=0
ADD_PR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --add) ADD_PR="${2:-}"; [[ -n "$ADD_PR" ]] || { echo "usage: train.sh --add <pr>" >&2; exit 2; }; shift ;;
        *) echo "usage: train.sh [--dry-run] | --add <pr>" >&2; exit 2 ;;
    esac
    shift
done

log()  { printf '[merge-train %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[merge-train %s] WARN: %s\n' "$(date +%H:%M:%S)" "$*"; }

command -v gh >/dev/null 2>&1 || { warn "gh is not on PATH"; exit 0; }

REPO="${MERGE_TRAIN_REPO:-}"
if [[ -z "$REPO" ]]; then
    REPO="$(cd "$REPO_ROOT" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || REPO=""
fi
[[ -n "$REPO" ]] || { warn "could not resolve the GitHub repo (offline, or not authenticated) — nothing to do."; exit 0; }

if [[ -n "$ADD_PR" ]]; then
    [[ "$ADD_PR" =~ ^[0-9]+$ ]] || { echo "not a PR number: $ADD_PR" >&2; exit 2; }
    gh label create "$LABEL" --repo "$REPO" --color 0E8A16 \
        --description "Merged to main by the merge train once CI is green" 2>/dev/null || true
    gh pr edit "$ADD_PR" --repo "$REPO" --add-label "$LABEL" >/dev/null || exit 1
    echo "on the train: #${ADD_PR}"
    exit 0
fi

mkdir -p "$STATE"
[[ -e "$STATE/PAUSED" ]] && exit 0

# --- Only one run at a time ------------------------------------------------------------------
# mkdir is atomic and macOS ships no flock(1). A dead pid in the lock means a crashed run:
# take the lock over rather than stay stuck forever.
if [[ "$DRY" == "0" ]]; then
    LOCK="$STATE/run.lock.d"
    if ! mkdir "$LOCK" 2>/dev/null; then
        old="$(cat "$LOCK/pid" 2>/dev/null || true)"
        if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
            log "another run is still going (pid $old) — skipping."
            exit 0
        fi
        log "stale lock (pid ${old:-?}) — taking over."
        rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || { log "lost the lock race — skipping."; exit 0; }
    fi
    echo $$ >"$LOCK/pid"
    trap 'rm -rf "$LOCK"' EXIT
fi

gh api user >/dev/null 2>&1 || { log "gh is offline or not authenticated — skipping."; exit 0; }

RUNS="$STATE/runs.tsv"
record() {  # action pr detail
    [[ "$DRY" == "1" ]] && return 0
    [[ -f "$RUNS" ]] || printf 'time\taction\tpr\tdetail\n' >"$RUNS"
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" >>"$RUNS"
}

if [[ "$DRY" == "0" ]]; then
    gh label create "$LABEL" --repo "$REPO" --color 0E8A16 \
        --description "Merged to main by the merge train once CI is green" 2>/dev/null || true
    gh label create "$FAILED_LABEL" --repo "$REPO" --color B60205 \
        --description "The merge train gave up on this PR; see its comment" 2>/dev/null || true
fi

fail() {  # pr reason
    local pr="$1" reason="$2"
    log "#${pr}: FAIL — ${reason}"
    record failed "$pr" "$reason"
    if [[ "$DRY" == "1" ]]; then return 0; fi
    gh pr edit "$pr" --repo "$REPO" --add-label "$FAILED_LABEL" >/dev/null 2>&1 || true
    gh pr comment "$pr" --repo "$REPO" --body "The merge train stopped on this PR: ${reason}

Fix it, then remove the \`${FAILED_LABEL}\` label to put it back on the train." >/dev/null 2>&1 || true
    osascript -e "display notification \"#${pr} stopped: ${reason}\" with title \"Merge train\"" >/dev/null 2>&1 || true
}

# Candidates, one TSV line each: number, head sha, mergeable, ci (green|red|pending), detail.
# Drafts and PRs already marked failed are dropped here. CI rule: any red entry is red; no
# entries or any unfinished entry is pending; otherwise green.
JSON="$(gh pr list --repo "$REPO" --state open --base main --label "$LABEL" --limit 100 \
    --json number,title,isDraft,headRefOid,headRefName,author,labels,mergeable,mergeStateStatus,statusCheckRollup,baseRefOid 2>/dev/null)" \
    || { warn "gh pr list failed — skipping."; exit 0; }

ROWS="$(FAILED_LABEL="$FAILED_LABEL" python3 -c '
import json, os, sys
RED = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"}
OK = {"SUCCESS", "NEUTRAL", "SKIPPED"}
for pr in sorted(json.load(sys.stdin), key=lambda p: p["number"]):
    if pr["isDraft"] or any(l["name"] == os.environ["FAILED_LABEL"] for l in pr["labels"]):
        continue
    reds, pending = [], False
    entries = pr.get("statusCheckRollup") or []
    for e in entries:
        if e.get("__typename") == "StatusContext":
            name, val = e.get("context", "?"), e.get("state") or ""
        else:
            name = e.get("name", "?")
            val = (e.get("conclusion") or "") if e.get("status") == "COMPLETED" else ""
        if val in RED: reds.append(name)
        elif val not in OK: pending = True
    ci = "red" if reds else ("pending" if (pending or not entries) else "green")
    print("\t".join([str(pr["number"]), pr["headRefOid"], pr["mergeable"], ci, ", ".join(reds)]))
' <<<"$JSON")" || { warn "could not parse the PR list — skipping."; exit 0; }

if [[ -z "$ROWS" ]]; then
    log "idle — no PRs on the train."
    record idle - "no candidates"
    exit 0
fi

ACTED=0
SKIPPED=0
while IFS=$'\t' read -r PR HEAD MERGEABLE CI DETAIL; do
    [[ -n "$PR" ]] || continue

    if [[ "$MERGEABLE" == "UNKNOWN" ]]; then
        log "#${PR}: mergeability pending — skipping this tick."; SKIPPED=1; continue
    fi
    if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
        fail "$PR" "merge conflict with main — rebase or resolve by hand, then remove ${FAILED_LABEL}"; continue
    fi
    if [[ "$CI" == "red" ]]; then
        fail "$PR" "CI failed (${DETAIL}) — https://github.com/${REPO}/pull/${PR}/checks"; continue
    fi
    if [[ "$CI" == "pending" ]]; then
        log "#${PR}: CI pending — skipping."; SKIPPED=1; continue
    fi

    MAIN_SHA="$(gh api "repos/${REPO}/commits/main" -q .sha 2>/dev/null)" || MAIN_SHA=""
    [[ -n "$MAIN_SHA" ]] || { warn "could not read main's HEAD — stopping this tick."; exit 0; }
    BEHIND="$(gh api "repos/${REPO}/compare/${MAIN_SHA}...${HEAD}" -q .behind_by 2>/dev/null)" || BEHIND=""
    [[ "$BEHIND" =~ ^[0-9]+$ ]] || { warn "#${PR}: could not compare with main — skipping."; SKIPPED=1; continue; }

    if (( BEHIND > 0 )); then
        if [[ "$DRY" == "1" ]]; then
            log "#${PR}: [dry-run] green but ${BEHIND} behind main — would update the branch (merge commit) and stop."
        else
            if gh pr update-branch "$PR" --repo "$REPO" >/dev/null 2>&1; then
                log "#${PR}: updated with main, CI re-runs; merges on a later tick."
                record updated "$PR" "${BEHIND} behind main"
            else
                fail "$PR" "could not bring up to date with main (conflict)"; continue
            fi
        fi
        ACTED=1; break
    fi

    if [[ "$DRY" == "1" ]]; then
        log "#${PR}: [dry-run] green and up to date — would merge (--merge, head ${HEAD:0:8}) and stop."
        ACTED=1; break
    fi
    if OUT="$(gh pr merge "$PR" --repo "$REPO" --merge --match-head-commit "$HEAD" --delete-branch 2>&1)"; then
        SHA="$(gh pr view "$PR" --repo "$REPO" --json mergeCommit -q .mergeCommit.oid 2>/dev/null || true)"
        log "#${PR}: merged ${SHA:0:8}."
        record merged "$PR" "${SHA:0:8}"
        gh pr comment "$PR" --repo "$REPO" --body "Merged to main by the merge train at ${SHA}. Not released: releases stay manual (scripts/create-release.sh)." >/dev/null 2>&1 || true
        ACTED=1; break
    fi
    fail "$PR" "merge failed: $(printf '%s' "$OUT" | head -n 3 | tr '\n' ' ')"
done <<<"$ROWS"

if (( ACTED == 0 )); then
    if (( SKIPPED == 1 )); then record skip - "waiting on CI or mergeability"; else record idle - "nothing mergeable"; fi
    log "done — nothing merged this tick."
fi
exit 0
