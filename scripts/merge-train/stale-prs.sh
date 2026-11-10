#!/usr/bin/env bash
# Weekly list of old pull requests — Mondays at 08:30 under launchd.
#
# Every open PR against main (drafts included) is classified by why it is still open.
# Age is whole days since createdAt. At 3 days it goes on the mail; at 14 days it is
# closed and the branch is kept. No mail when nothing is that old. See
# scripts/merge-train/README.md.
#
#     stale-prs.sh [--dry-run]   print the mail, close nothing, send nothing
#
# The train's PAUSED file does not suppress this list. State dir: $MERGE_TRAIN_STATE,
# default ~/.local/state/whispershortcut-merge-train.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Survives the plist's re-exec of the origin/main copy, where SCRIPT_DIR is /tmp.
REPO_ROOT="${MERGE_TRAIN_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# launchd's `bash -lc` has no ~/.local/bin or Homebrew on PATH (the additions live in ~/.zshrc).
for extra in "${HOME}/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    [[ -d "$extra" ]] && case ":${PATH}:" in *":${extra}:"*) ;; *) export PATH="${extra}:${PATH}" ;; esac
done

STATE="${MERGE_TRAIN_STATE:-${HOME}/.local/state/whispershortcut-merge-train}"
LABEL="${MERGE_TRAIN_LABEL:-merge-train}"
RUNS="$STATE/stale-runs.tsv"
DRY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        *) echo "usage: stale-prs.sh [--dry-run]" >&2; exit 2 ;;
    esac
    shift
done

log()  { printf '[stale-prs %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[stale-prs %s] WARN: %s\n' "$(date +%H:%M:%S)" "$*"; }
notify() {
    local title="$1" text="$2" qtitle qtext
    qtitle="$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    qtext="$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    osascript -e "display notification \"${qtext}\" with title \"${qtitle}\"" >/dev/null 2>&1 || true
}
record() {  # listed closed — listed is everyone in the mail, closed is the subset closed this run
    [[ "$DRY" == "1" ]] && return 0
    mkdir -p "$STATE"
    [[ -f "$RUNS" ]] || printf 'time\tlisted\tclosed\n' >"$RUNS"
    printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" >>"$RUNS"
}

command -v gh >/dev/null 2>&1 || { warn "gh is not on PATH"; exit 0; }

REPO="${MERGE_TRAIN_REPO:-}"
if [[ -z "$REPO" ]]; then
    REPO="$(cd "$REPO_ROOT" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || REPO=""
fi
[[ -n "$REPO" ]] || { warn "could not resolve the GitHub repo (offline, or not authenticated) — nothing to do."; exit 0; }

mkdir -p "$STATE"
gh api user >/dev/null 2>&1 || { log "gh is offline or not authenticated — skipping."; exit 0; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/stale-prs.XXXXXX")" || { warn "mktemp failed"; exit 0; }
trap 'rm -rf "$tmp"' EXIT

if ! gh pr list --repo "$REPO" --state open --base main --limit 100 \
    --json number,title,isDraft,createdAt,headRefName,author,labels,mergeable,statusCheckRollup \
    >"$tmp/prs.json" 2>"$tmp/list.err"; then
    warn "gh pr list failed — skipping. $(head -n 1 "$tmp/list.err" 2>/dev/null)"
    exit 0
fi

export REPO LABEL
export REPO_OWNER="${REPO%%/*}"
cat >"$tmp/sweep.py" <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timezone

REPO = os.environ["REPO"]
OWNER = os.environ["REPO_OWNER"]
OPTIN = os.environ.get("LABEL", "merge-train")
FAILED = "merge-train-failed"
PREFIX = "The merge train stopped on this PR:"
RED = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"}
OK = {"SUCCESS", "NEUTRAL", "SKIPPED"}
DEPENDABOT = {"app/dependabot", "dependabot[bot]"}
FOOTER = (
    "Opt-out-Labels: hold, needs-device-test. "
    "Alles andere ohne Konflikt und mit grüner CI mergt der Merge-Train."
)


def trusted(author):
    login = (author or {}).get("login") or ""
    return login == OWNER or login in DEPENDABOT


def ci_of(pr):
    reds, pending = [], False
    entries = pr.get("statusCheckRollup") or []
    for e in entries:
        if e.get("__typename") == "StatusContext":
            name, val = e.get("context", "?"), e.get("state") or ""
        else:
            name = e.get("name", "?")
            val = (e.get("conclusion") or "") if e.get("status") == "COMPLETED" else ""
        if val in RED:
            reds.append(name)
        elif val not in OK:
            pending = True
    if reds:
        return "red", reds
    if pending or not entries:
        return "pending", []
    return "green", []


def stopped_detail(number):
    """Text after the train's stop prefix, from the newest matching issue comment."""
    try:
        out = subprocess.run(
            ["gh", "pr", "view", str(number), "--repo", REPO, "--json", "comments"],
            check=True, capture_output=True, text=True, timeout=60)
        comments = json.loads(out.stdout).get("comments") or []
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return "siehe PR"
    hits = []
    for c in comments:
        lines = (c.get("body") or "").splitlines()
        first = lines[0].strip() if lines else ""
        if first.startswith(PREFIX):
            hits.append((c.get("createdAt") or "", first[len(PREFIX):].strip()))
    if not hits:
        return "siehe PR"
    hits.sort(key=lambda h: h[0])
    return hits[-1][1] or "siehe PR"


def reason_for(pr, names):
    # First match wins. Same trust rule as train.sh.
    if "needs-device-test" in names:
        return "wartet auf Gerätetest"
    if "hold" in names:
        return "hold"
    if FAILED in names:
        return "Merge-Train gestoppt: " + stopped_detail(pr["number"])
    if pr.get("isDraft"):
        return "Draft"
    if (pr.get("mergeable") or "") == "CONFLICTING":
        return "Merge-Konflikt"
    ci, reds = ci_of(pr)
    if ci == "red":
        return "CI rot: " + ", ".join(reds)
    if ci == "pending":
        return "CI läuft / nicht gestartet"
    if not trusted(pr.get("author")) and OPTIN not in names:
        return "externer PR, wartet auf Review"
    if (pr.get("headRefName") or "").startswith("implementer/"):
        return "implementer, eigenes Merge-Fenster"
    return "grün, wartet auf den Merge-Train"


def classify(src, dest):
    with open(src, encoding="utf-8") as f:
        prs = json.load(f)
    now = datetime.now(timezone.utc)
    items = []
    for pr in prs:
        created = datetime.fromisoformat(pr["createdAt"].replace("Z", "+00:00"))
        age = (now - created).days
        if age < 3:
            continue
        names = {l.get("name", "") for l in (pr.get("labels") or [])}
        items.append({
            "number": pr["number"],
            "age": age,
            "title": " ".join((pr.get("title") or "").split()),
            "reason": " ".join(reason_for(pr, names).splitlines()),
            "close": age >= 14,
            "url": f"https://github.com/{REPO}/pull/{pr['number']}",
        })
    with open(dest, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False)


def close_list(src):
    with open(src, encoding="utf-8") as f:
        items = json.load(f)
    for it in items:
        if it["close"]:
            sys.stdout.write(f"{it['number']}\x1f{it['age']}\x1f{it['reason']}\n")


def render(src, closed_path, body_path):
    with open(src, encoding="utf-8") as f:
        items = json.load(f)
    closed_ids = set()
    if os.path.exists(closed_path):
        with open(closed_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    closed_ids.add(int(line))
    closed = sorted((it for it in items if it["number"] in closed_ids),
                    key=lambda it: (-it["age"], it["number"]))
    rest = sorted((it for it in items if it["number"] not in closed_ids),
                  key=lambda it: (-it["age"], it["number"]))

    def line(it):
        return f"#{it['number']} ({it['age']} T) {it['title']} — {it['reason']} — {it['url']}"

    parts = []
    if closed:
        parts.append("Automatisch geschlossen (14 Tage):")
        parts.extend(line(it) for it in closed)
        parts.append("")
    if rest:
        parts.extend(line(it) for it in rest)
        parts.append("")
    parts.append(FOOTER)
    with open(body_path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts) + "\n")
    print(f"{len(items)} {len(closed)}")


mode = sys.argv[1]
if mode == "classify":
    classify(sys.argv[2], sys.argv[3])
elif mode == "close-list":
    close_list(sys.argv[2])
elif mode == "render":
    render(sys.argv[2], sys.argv[3], sys.argv[4])
else:
    sys.exit(f"unknown mode {mode}")
PY

if ! python3 "$tmp/sweep.py" classify "$tmp/prs.json" "$tmp/items.json"; then
    warn "could not classify PRs — skipping."
    exit 0
fi

n_items="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8"))))' "$tmp/items.json")" \
    || { warn "could not read the classified list — skipping."; exit 0; }
if [[ "$n_items" == "0" ]]; then
    record 0 0
    log "no open PR older than 3 days."
    exit 0
fi

: >"$tmp/closed.txt"
while IFS=$'\x1f' read -r num age reason; do
    [[ -n "${num:-}" ]] || continue
    comment="Closed automatically after 14 days open (reason: ${reason}). The branch is kept; reopen this PR or open a new one from it when it is picked up again."
    if [[ "$DRY" == "1" ]]; then
        printf '%s\n' "$num" >>"$tmp/closed.txt"
        continue
    fi
    if out="$(gh pr close "$num" --repo "$REPO" --comment "$comment" 2>&1)"; then
        log "#${num}: closed after ${age} days."
        printf '%s\n' "$num" >>"$tmp/closed.txt"
    else
        warn "#${num}: could not close — $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"
    fi
done < <(python3 "$tmp/sweep.py" close-list "$tmp/items.json")

if ! read -r LISTED CLOSED < <(python3 "$tmp/sweep.py" render "$tmp/items.json" "$tmp/closed.txt" "$tmp/body.txt"); then
    warn "could not render the mail — skipping."
    exit 0
fi
[[ -n "${LISTED:-}" && -n "${CLOSED:-}" ]] || { warn "could not render the mail — skipping."; exit 0; }

subject="Offene PRs: ${LISTED} älter als 3 Tage"
if [[ "$CLOSED" =~ ^[0-9]+$ ]] && (( CLOSED > 0 )); then
    subject="${subject}, ${CLOSED} geschlossen"
fi

if [[ "$DRY" == "1" ]]; then
    printf 'Subject: %s\n\n' "$subject"
    cat "$tmp/body.txt"
    exit 0
fi

CONFIG_FILE="${HOME}/.config/whispershortcut-implementer/env"
if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || warn "could not read ${CONFIG_FILE}"
    set +a
fi
MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"
if ! python3 "${REPO_ROOT}/scripts/send-report-mail.py" --to "$MAIL_TO" --subject "$subject" --body-file "$tmp/body.txt" \
    --verdict fyi --verdict-detail "Nichts zu tun, außer du willst einen der PRs fertig machen; der Merge-Train mergt grüne PRs selbst."; then
    kept="${STATE}/stale-last-mail.txt"
    cp "$tmp/body.txt" "$kept" 2>/dev/null || true
    warn "could not send mail — see ${kept}"
fi
notify "Offene PRs" "$subject"
record "$LISTED" "$CLOSED"
exit 0
