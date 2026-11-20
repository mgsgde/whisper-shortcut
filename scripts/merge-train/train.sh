#!/usr/bin/env bash
# The merge train — every 20 minutes under launchd.
#
# Why: a finished PR with green CI should not wait for somebody to click merge. Dependabot PRs
# sat open for a week; implementer and session PRs wait the same way. Ported from a sibling
# project's merge train; see scripts/merge-train/README.md.
#
# What it does: takes open, non-draft PRs against main and DRAINS them each tick: every candidate
# whose CI is green and that GitHub reports MERGEABLE is merged, in ascending PR number. A PR that
# is behind main is merged as it is; the train never updates branches (no `gh pr update-branch`,
# no waiting for a second CI run). Opt-out (skipped silently, never failed): labels
# `merge-train-failed`, `hold`, `needs-device-test`; drafts; a branch starting with `implementer/`;
# an author who is not the repo owner or Dependabot. The last two are included when the PR
# carries `merge-train`.
#
# Why drain instead of one-at-a-time: two green PRs can still conflict semantically once both are
# on main. That is caught by CI on main (ci.yml runs on push to main), and the Dev app only
# installs green main commits (scripts/dev-daily.sh). The safety net is therefore a main-CI
# brake: before merging anything, the newest completed CI push run on main is looked up; if it
# is red, nothing is merged this tick, a notification fires and ONE mail per red sha goes out.
#
# What it never does: tag, release, touch the parent repo's submodule pointer, or touch any
# local checkout. Merging happens GitHub-side through gh, so no local git state matters.
# Releases are cut by scripts/release-nightly-job.sh.
#
#     train.sh [--dry-run]     read everything, decide, print what it would do, change nothing
#     train.sh --add <pr>      add the `merge-train` label (explicit opt-in)
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
    gh label create "hold" --repo "$REPO" --color FBCA04 \
        --description "Merge train: never merge this PR automatically" 2>/dev/null || true
    gh label create "needs-device-test" --repo "$REPO" --color 1D76DB \
        --description "Waits on a manual test on a device; the merge train skips it" 2>/dev/null || true
fi

fail() {  # pr reason
    local pr="$1" reason="$2"
    log "#${pr}: FAIL — ${reason}"
    record failed "$pr" "$reason"
    if [[ "$DRY" == "1" ]]; then return 0; fi
    gh pr edit "$pr" --repo "$REPO" --add-label "$FAILED_LABEL" >/dev/null 2>&1 || true
    gh pr comment "$pr" --repo "$REPO" --body "The merge train stopped on this PR: ${reason}

Fix it, then remove the \`${FAILED_LABEL}\` label. The train picks the PR up again on its own unless it is opted out (\`hold\`, \`needs-device-test\`, a draft, an \`implementer/\` branch, or an author other than the repo owner or Dependabot — those last two need the \`${LABEL}\` label)." >/dev/null 2>&1 || true
    osascript -e "display notification \"#${pr} stopped: ${reason}\" with title \"Merge train\"" >/dev/null 2>&1 || true
}

# --- Main-CI brake ---------------------------------------------------------------------------
# The newest COMPLETED CI push run on main decides. Red (failure/timed_out; cancelled and skipped runs are ignored): merge
# nothing, tell Magnus once per red sha. No push run yet, or gh fails: do not block.
main_ci_red() {  # prints "<sha>\t<url>" when main is red
    local json line
    json="$(gh run list --repo "$REPO" --workflow CI --branch main --event push --limit 10 \
        --json headSha,status,conclusion,url 2>/dev/null)" || return 1
    line="$(python3 -c '
import json, sys
try: runs = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in runs:
    if r.get("status") == "completed" and r.get("conclusion") in ("success", "failure", "timed_out"):
        if r.get("conclusion") != "success":
            print(r["headSha"] + "\t" + (r.get("url") or ""))
        break
' <<<"$json")"
    [[ -n "$line" ]] || return 1
    printf '%s\n' "$line"
}

if RED="$(main_ci_red)"; then
    RED_SHA="${RED%%$'\t'*}"; RED_URL="${RED#*$'\t'}"
    log "main CI is red at ${RED_SHA:0:8} — merging nothing this tick. ${RED_URL}"
    if [[ "$DRY" == "1" ]]; then
        log "[dry-run] would record 'blocked main-red', notify, and mail once for this sha."
        exit 0
    fi
    record blocked - "main-red ${RED_SHA}"
    if [[ "$(cat "$STATE/main-red-mailed" 2>/dev/null || true)" != "$RED_SHA" ]]; then
        osascript -e "display notification \"main CI red at ${RED_SHA:0:8}, merge train paused\" with title \"Merge train\"" >/dev/null 2>&1 || true
        BODY="$(mktemp -t merge-train-red)"
        GREEN_SHA="$(gh run list --repo "$REPO" --workflow CI --branch main --event push --status success --limit 1 \
            --json headSha -q '.[0].headSha' 2>/dev/null || true)"
        {
            echo "Main CI is red at ${RED_SHA}."
            echo "Run: ${RED_URL}"
            echo
            if [[ -n "$GREEN_SHA" ]]; then
                echo "Commits since the last green run (${GREEN_SHA:0:8}):"
                gh api "repos/${REPO}/compare/${GREEN_SHA}...${RED_SHA}" \
                    -q '.commits[].commit.message | split("\n")[0]' 2>/dev/null || true
            else
                echo "No earlier green CI run on main was found."
            fi
            echo
            echo "The merge train merges nothing until a newer CI run on main finishes green."
        } >"$BODY"
        if python3 "$REPO_ROOT/scripts/send-report-mail.py" \
            --subject "Merge train paused: main CI red at ${RED_SHA:0:8}" --body-file "$BODY" --verdict needs-fix >/dev/null 2>&1; then
            echo "$RED_SHA" >"$STATE/main-red-mailed"
        else
            warn "could not send the main-red mail."
        fi
        rm -f "$BODY"
    fi
    exit 0
fi

# Candidates, one TSV line each: number, head sha, mergeable, ci (green|red|pending), detail.
# Dropped silently: drafts; labels merge-train-failed, hold, needs-device-test; an
# implementer/ branch or an author other than the repo owner or Dependabot, unless the PR
# carries merge-train. CI rule: any red entry is red; no entries or any unfinished entry is
# pending; otherwise green.
JSON="$(gh pr list --repo "$REPO" --state open --base main --limit 100 \
    --json number,title,isDraft,headRefOid,headRefName,author,labels,mergeable,mergeStateStatus,statusCheckRollup,baseRefOid 2>/dev/null)" \
    || { warn "gh pr list failed — skipping."; exit 0; }

ROWS="$(FAILED_LABEL="$FAILED_LABEL" LABEL="$LABEL" REPO_OWNER="${REPO%%/*}" python3 -c '
import json, os, sys
RED = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"}
OK = {"SUCCESS", "NEUTRAL", "SKIPPED"}
FAILED = os.environ["FAILED_LABEL"]
OPTIN = os.environ["LABEL"]
OWNER = os.environ["REPO_OWNER"]
OPT_OUT = {"hold", "needs-device-test"}
DEPENDABOT = {"app/dependabot", "dependabot[bot]"}

def trusted(author):
    login = (author or {}).get("login") or ""
    return login == OWNER or login in DEPENDABOT

for pr in sorted(json.load(sys.stdin), key=lambda p: p["number"]):
    names = {l["name"] for l in pr["labels"]}
    if pr["isDraft"] or FAILED in names or names & OPT_OUT:
        continue
    opted_in = OPTIN in names
    if (pr.get("headRefName") or "").startswith("implementer/") and not opted_in:
        continue
    if not trusted(pr.get("author")) and not opted_in:
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
    # mergeable is null until GitHub has computed it. Treat that as UNKNOWN so one such PR
    # cannot abort the whole tick (the candidate set is every open PR now).
    mergeable = pr.get("mergeable") or "UNKNOWN"
    print("\t".join([str(pr["number"]), pr.get("headRefOid") or "", mergeable, ci, ", ".join(reds)]))
' <<<"$JSON")" || { warn "could not parse the PR list — skipping."; exit 0; }

if [[ -z "$ROWS" ]]; then
    log "idle — no PRs on the train."
    record idle - "no candidates"
    exit 0
fi

ACTED=0
SKIPPED=0
MERGED_THIS_TICK=0
while IFS=$'\t' read -r PR HEAD MERGEABLE CI DETAIL; do
    [[ -n "$PR" ]] || continue

    if [[ "$MERGEABLE" == "UNKNOWN" ]]; then
        log "#${PR}: mergeability pending — skipping this tick."; SKIPPED=1; continue
    fi
    if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
        if (( MERGED_THIS_TICK == 1 )); then
            log "#${PR}: conflicts after this tick's merges — retry next tick."; SKIPPED=1; continue
        fi
        fail "$PR" "merge conflict with main — rebase or resolve by hand, then remove ${FAILED_LABEL}"; continue
    fi
    if [[ "$CI" == "red" ]]; then
        fail "$PR" "CI failed (${DETAIL}) — https://github.com/${REPO}/pull/${PR}/checks"; continue
    fi
    if [[ "$CI" == "pending" ]]; then
        log "#${PR}: CI pending — skipping."; SKIPPED=1; continue
    fi

    if [[ "$DRY" == "1" ]]; then
        log "#${PR}: [dry-run] green and mergeable — would merge (--merge, head ${HEAD:0:8})."
        ACTED=$((ACTED + 1)); continue
    fi
    if OUT="$(gh pr merge "$PR" --repo "$REPO" --merge --match-head-commit "$HEAD" --delete-branch 2>&1)"; then
        SHA="$(gh pr view "$PR" --repo "$REPO" --json mergeCommit -q .mergeCommit.oid 2>/dev/null || true)"
        log "#${PR}: merged ${SHA:0:8}."
        record merged "$PR" "${SHA:0:8}"
        gh pr comment "$PR" --repo "$REPO" --body "Merged to main by the merge train at ${SHA}. Released automatically by the nightly release job (scripts/release-nightly-job.sh)." >/dev/null 2>&1 || true
        ACTED=$((ACTED + 1)); MERGED_THIS_TICK=1; continue
    fi
    if (( MERGED_THIS_TICK == 1 )); then
        log "#${PR}: merge failed after this tick's merges — retry next tick."; SKIPPED=1; continue
    fi
    fail "$PR" "merge failed: $(printf '%s' "$OUT" | head -n 3 | tr '\n' ' ')"
done <<<"$ROWS"

if (( ACTED == 0 )); then
    if (( SKIPPED == 1 )); then record skip - "waiting on CI or mergeability"; else record idle - "nothing mergeable"; fi
    log "done — nothing merged this tick."
fi
exit 0
