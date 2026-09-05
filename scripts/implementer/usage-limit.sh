#!/usr/bin/env bash
# Detect LLM usage/rate limits in agent logs and wait until they reset.
#
# Ported from sabaki.dance's scripts/implementer/usage-limit.sh (2026-09-03).
#
# `claude -p` exits on session/weekly/opus limits — auto-continue is interactive-only — and
# cursor-agent does the same. Without a wait the runner treats that as a build failure: it
# mails FAILED, keeps a worktree for a post-mortem there is nothing to see in, and that stale
# worktree then blocks the next tick. A quota that resets in 40 minutes is not a failure.
#
# Sourced by run-implementer.sh. Also runnable as:
#   bash scripts/implementer/usage-limit.sh --self-test
#
# This is NOT the monthly run budget (runs-YYYY-MM). That is a different cap, it is about
# money rather than throttling, and it still refuses the run until the month rolls over.

usage_limit_pattern() {
    # Keep "not your usage limit" out: Claude uses that phrase for a server-side throttle that
    # is explicitly not the plan quota, and waiting hours for it would be waiting for nothing.
    printf '%s' 'hit your (session|weekly|opus|sonnet) limit|usage limit reached|you.?ve hit your usage limit|resource_exhausted|rate_limit_error|rate limit exceeded|spend limit reached|out of extra usage|request rejected \(429\)|too many requests'
}

usage_limit_in_log() {
    local log_file="$1"
    [[ -f "$log_file" ]] || return 1
    grep -qiE "$(usage_limit_pattern)" "$log_file"
}

format_epoch() {
    date -r "$1" 2>/dev/null || date -d "@$1" 2>/dev/null || echo "$1"
}

# Prints the epoch of the LAST "resets …" in the log, or nothing. Last, not first: a retried
# attempt appends, and the newest line is the one that still applies.
parse_usage_reset_epoch() {
    local log_file="$1"
    python3 - "$log_file" <<'PY'
import re, sys
from datetime import datetime, timedelta, timezone

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
now = datetime.now().astimezone()

found = []
for m in re.finditer(r"resets\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s*UTC", raw, re.I):
    found.append((m.start(), "utc", m.groups()))
for m in re.finditer(r"resets\s+([A-Za-z]{3})\s+(\d{1,2}:\d{2}\s*[ap]m)", raw, re.I):
    found.append((m.start(), "weekday", m.groups()))
for m in re.finditer(r"resets\s+(\d{1,2}:\d{2}\s*[ap]m)", raw, re.I):
    found.append((m.start(), "tod", m.groups()))
if not found:
    sys.exit(0)
found.sort()
_, kind, groups = found[-1]


def parse_ampm(s):
    return datetime.strptime(s.replace(" ", "").upper(), "%I:%M%p").time()


try:
    if kind == "utc":
        dt = datetime.strptime(f"{groups[0]} {groups[1]}", "%Y-%m-%d %H:%M").replace(
            tzinfo=timezone.utc
        )
    elif kind == "tod":
        t = parse_ampm(groups[0])
        dt = now.replace(hour=t.hour, minute=t.minute, second=0, microsecond=0)
        if dt <= now:
            dt += timedelta(days=1)
    else:
        t = parse_ampm(groups[1])
        want = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].index(groups[0][:3].lower())
        dt = now.replace(hour=t.hour, minute=t.minute, second=0, microsecond=0)
        dt += timedelta(days=(want - dt.weekday()) % 7)
        if dt <= now:
            dt += timedelta(days=7)
    print(int(dt.timestamp()))
except Exception:
    sys.exit(0)
PY
}

# Sleep until $1 (epoch). Polls in one-minute steps rather than sleeping the whole span at
# once: this is a laptop, `sleep` is frozen while the lid is shut but wall-clock is not, so a
# single long sleep overshoots the reset by however long the machine was away.
wait_until_epoch() {
    local target="$1"
    while (( $(date +%s) < target )); do
        sleep 60
    done
    sleep 15
}

if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == "--self-test" ]]; then
    set -euo pipefail
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT

    printf '%s\n' "You've hit your session limit · resets 3:45pm" >"$tmp"
    usage_limit_in_log "$tmp" || { echo "FAIL: session limit not detected"; exit 1; }
    epoch=$(parse_usage_reset_epoch "$tmp")
    [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]] || { echo "FAIL: 3:45pm did not parse ($epoch)"; exit 1; }

    printf '%s\n' "You've hit your weekly limit · resets Mon 12:00am" >"$tmp"
    usage_limit_in_log "$tmp" || { echo "FAIL: weekly limit not detected"; exit 1; }
    epoch=$(parse_usage_reset_epoch "$tmp")
    [[ -n "$epoch" ]] || { echo "FAIL: Mon 12:00am did not parse"; exit 1; }

    printf '%s\n' "spend limit reached (daily; resets 2026-08-09 00:00 UTC)" >"$tmp"
    usage_limit_in_log "$tmp" || { echo "FAIL: spend limit not detected"; exit 1; }
    epoch=$(parse_usage_reset_epoch "$tmp")
    [[ "$epoch" == "1786233600" ]] || { echo "FAIL: UTC date parsed as $epoch, want 1786233600"; exit 1; }

    printf '%s\n' "API Error: Server is temporarily limiting requests (not your usage limit)" >"$tmp"
    if usage_limit_in_log "$tmp"; then
        echo "FAIL: 'not your usage limit' was treated as a plan quota"; exit 1
    fi

    printf '%s\n' "some other error, nothing about quotas" >"$tmp"
    if usage_limit_in_log "$tmp"; then
        echo "FAIL: unrelated log matched"; exit 1
    fi

    echo "usage-limit.sh self-test: ok"
fi
