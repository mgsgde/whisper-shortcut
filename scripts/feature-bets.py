#!/usr/bin/env python3
"""Grade feature bets from plans/feature-bets.md.

A row is a bet. After it has been in a release for its window, a feature used on
fewer than 3 distinct days — on this Mac, or estimated from opt-in telemetry —
is REVIEW. This script never removes a feature. Magnus decides; a non-empty
Decision cell is DECIDED and is not graded again.

    python3 scripts/feature-bets.py
    python3 scripts/feature-bets.py --no-remote --today 2026-10-29
    python3 scripts/feature-bets.py --json
    python3 scripts/feature-bets.py --write "$WS_BUSINESS_DIR/feature-bets"
    python3 scripts/feature-bets.py --local /path/to/feature-usage.json --ledger plans/feature-bets.md

"andere" is an estimate: the telemetry total for a day minus this Mac's count
for that day. Pings carry no install id.

Exit codes: 0 graded (a missing local file or a failed BigQuery read is reported,
not fatal), 2 bad arguments.
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER_REL = "plans/feature-bets.md"
DEFAULT_LEDGER = os.path.join(REPO, LEDGER_REL)
DEFAULT_LOCAL = os.path.expanduser(
    "~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/"
    "Application Support/WhisperShortcut/feature-usage.json"
)
# Fully-qualified so the query does not depend on `gcloud` config. Same table as
# scripts/telemetry-report.sh.
BQ_TABLE = "`whisper-shortcut.telemetry.run_googleapis_com_stdout`"
DAY_THRESHOLD = 3
TAG_RE = re.compile(r"v\d+(?:\.\d+)*")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ORDER = ("REVIEW", "RUNNING", "KEEP", "WAITING", "DECIDED")
# Offline Mode turns telemetry off, so other installs are invisible. Local days still grade it.
BLIND_FEATURES = {"offlineMode"}

# TelemetryService.flush sends a completed local day only (`day key < todayKey`):
# today is still filling, so the ping leaves on a later calendar day — at the
# earliest, the day after the counted day. The counted day is therefore
# DATE(timestamp) - 1. A ping held back longer (the app stayed closed) is
# attributed one day early; "andere" stays an estimate. BigQuery's DATE() is UTC,
# the store's keys are the Mac's local calendar.
REMOTE_SQL = f"""
SELECT JSON_VALUE(f, '$.key') AS feature,
       FORMAT_DATE('%Y-%m-%d', DATE_SUB(DATE(timestamp), INTERVAL 1 DAY)) AS day,
       SUM(CAST(CAST(JSON_VALUE(f, '$.n') AS FLOAT64) AS INT64)) AS n
FROM (
  SELECT timestamp, TO_JSON_STRING(jsonPayload.telemetry) AS j
  FROM {BQ_TABLE}
)
, UNNEST(JSON_QUERY_ARRAY(j, '$.features')) AS f
WHERE JSON_VALUE(j, '$.kind') = 'daily'
  AND JSON_VALUE(j, '$.app') != '0.0'
GROUP BY feature, day
"""


def parse_ledger(text):
    """Rows of the ledger table. The feature id is the backticked token in column 1."""
    rows = []
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            continue
        # The header cell starts with "Feature"; a separator is dashes. An id such as
        # `waitingFeature` contains that word and must still be a row.
        if cells[0].startswith("Feature") or cells[0].startswith("-"):
            continue
        match = re.search(r"`([^`]+)`", cells[0])
        if not match:
            continue
        window = cells[3].strip()
        number = re.match(r"(\d+)", window)
        rows.append({
            "feature": match.group(1),
            "what": cells[1].strip(),
            "added": cells[2].strip(),
            "window": window,
            "window_days": int(number.group(1)) if number else 21,
            "decision": cells[4].strip(),
        })
    return rows


def _git(args):
    proc = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _pickaxe(feature_id, added_only):
    # -S looks for the backticked id, the same token the ledger table uses.
    cmd = ["git", "log", "--format=%H"]
    if added_only:
        cmd.append("--diff-filter=A")
    cmd += ["-S", f"`{feature_id}`", "--", LEDGER_REL]
    return _git(cmd)


def git_introducing_commit(feature_id):
    """Oldest commit that introduced the row.

    The requested pickaxe is `git log --diff-filter=A -S'<id>'`. That filter only
    matches a commit that adds the file, which is right for the seed rows and
    empty for a row a later PR appends (the spec: the feature's own PR edits the
    ledger). When the file-add search is empty, the same pickaxe without the
    filter is the commit that introduced the id. `git log` is newest-first, so
    the oldest hash is the last line.
    """
    shas = _pickaxe(feature_id, added_only=True)
    if not shas:
        shas = _pickaxe(feature_id, added_only=False)
    return shas[-1] if shas else None


def git_first_tag(sha):
    """First `v*` tag whose commit contains `sha`, oldest creatordate first."""
    tags = _git(["git", "tag", "--contains", sha, "--sort=creatordate", "v*"])
    return tags[0] if tags else None


def git_tag_date(tag):
    """Committer date of the tag, ISO 8601 (`%cI`). Empty when the tag is unknown."""
    stamps = _git(["git", "log", "-1", "--format=%cI", tag])
    return stamps[0] if stamps else None


def date_from_stamp(stamp):
    """The calendar date in the stamp's own offset (`2026-10-01T09:00:00+02:00`)."""
    if not stamp:
        return None
    stamp = stamp.strip()
    if len(stamp) >= 10 and DAY_RE.match(stamp[:10]):
        return dt.date.fromisoformat(stamp[:10])
    return None


def release_start(row, git_commit, git_tag, git_date):
    """Publish date of the release that contains the row, or None when it is not out yet.

    A non-"next" Added value that is a tag name (v8.70) is that release directly.
    """
    added = row["added"].strip()
    if added and added != "next" and TAG_RE.fullmatch(added):
        return date_from_stamp(git_date(added))
    sha = git_commit(row["feature"])
    if not sha:
        return None
    tag = git_tag(sha)
    if not tag:
        return None
    return date_from_stamp(git_date(tag))


def load_local(path):
    """`(days_by_feature, problem)`. A missing or unreadable file is a problem, not an exception."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return {}, f"Lokale Datei fehlt: {path}"
    except (OSError, json.JSONDecodeError, UnicodeError) as exc:
        return {}, f"Lokale Datei unlesbar: {path} ({exc.__class__.__name__})"
    entries = data.get("entries") if isinstance(data, dict) else None
    if not isinstance(entries, dict):
        return {}, f"Lokale Datei unlesbar: {path} (kein entries-Objekt)"
    out = {}
    for feature, entry in entries.items():
        if not isinstance(entry, dict):
            continue
        days = entry.get("days") or {}
        if not isinstance(days, dict):
            continue
        parsed = {}
        for day, count in days.items():
            if not isinstance(day, str) or not DAY_RE.match(day):
                continue
            try:
                parsed[day] = int(count)
            except (TypeError, ValueError):
                continue
        out[str(feature)] = parsed
    return out, None


def resolve_bq():
    """Path to the bq CLI.

    launchd's PATH is minimal and does not include the Cloud SDK, so a miss on PATH falls
    back to the two layouts this machine uses.
    """
    found = shutil.which("bq")
    if found:
        return found
    for candidate in (
        os.path.expanduser("~/google-cloud-sdk/google-cloud-sdk/bin/bq"),
        os.path.expanduser("~/google-cloud-sdk/bin/bq"),
    ):
        if os.path.isfile(candidate):
            return candidate
    return "bq"


def bq_feature_days():
    """`{feature: {yyyy-MM-dd: count}}` from opt-in daily pings, or None when bq fails.

    See REMOTE_SQL: the counted day is the send date minus one day.
    """
    cmd = [
        resolve_bq(), "query",
        "--nouse_legacy_sql",
        "--format=json",
        "--project_id=whisper-shortcut",
        "--max_rows=1000000",
        "--quiet",
        REMOTE_SQL,
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"feature bets: bq failed ({exc})", file=sys.stderr)
        return None
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        tail = detail[-1] if detail else "no output"
        print(f"feature bets: bq failed (exit {proc.returncode}): {tail}", file=sys.stderr)
        return None
    try:
        payload = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        print("feature bets: bq returned non-JSON", file=sys.stderr)
        return None
    if not isinstance(payload, list):
        print("feature bets: bq JSON was not a list", file=sys.stderr)
        return None
    out = {}
    for row in payload:
        if not isinstance(row, dict):
            continue
        feature = row.get("feature")
        day = row.get("day")
        if not feature or not isinstance(day, str) or not DAY_RE.match(day):
            continue
        try:
            count = int(float(row.get("n") or 0))
        except (TypeError, ValueError):
            continue
        bucket = out.setdefault(str(feature), {})
        bucket[day] = bucket.get(day, 0) + count
    return out


def _in_window(day, start, end):
    if not DAY_RE.match(day):
        return False
    current = dt.date.fromisoformat(day)
    return start <= current < end


def own_days(local_days, start, end, today):
    """Distinct local days in the window with a count above zero.

    A window that is still open only counts days up to today.
    """
    limit = min(end, today + dt.timedelta(days=1))
    return sum(
        1 for day, count in local_days.items()
        if count > 0 and _in_window(day, start, limit)
    )


def others_days(remote_days, local_days, start, end):
    """Days in the window where the telemetry total exceeds this Mac's count."""
    days = set(remote_days) | set(local_days)
    found = 0
    for day in days:
        if not _in_window(day, start, end):
            continue
        if remote_days.get(day, 0) - local_days.get(day, 0) > 0:
            found += 1
    return found


def grade_row(row, today, start, local_days, remote_days, remote_ok):
    """One ledger row. Decision wins over the clock. No release yet is WAITING."""
    feature = row["feature"]
    blind = feature in BLIND_FEATURES
    base = {
        "feature": feature,
        "what": row["what"],
        "added": row["added"],
        "window": row["window"],
        "window_days": row["window_days"],
        "decision": row["decision"],
        "blind": blind,
        "start": start.isoformat() if start else None,
        "end": None,
        "days_left": None,
        "own_days": 0,
        "others_days": 0,
        "used_days": 0,
    }
    if row["decision"]:
        base["status"] = "DECIDED"
        return base
    if start is None:
        base["status"] = "WAITING"
        return base
    end = start + dt.timedelta(days=row["window_days"])
    base["end"] = end.isoformat()
    local = local_days.get(feature, {})
    remote = {} if blind or not remote_ok else remote_days.get(feature, {})
    base["own_days"] = own_days(local, start, end, today)
    base["others_days"] = 0 if blind or not remote_ok else others_days(remote, local, start, end)
    base["used_days"] = max(base["own_days"], base["others_days"])
    if today < end:
        base["status"] = "RUNNING"
        base["days_left"] = (end - today).days
        return base
    if base["own_days"] >= DAY_THRESHOLD or base["others_days"] >= DAY_THRESHOLD:
        base["status"] = "KEEP"
    else:
        base["status"] = "REVIEW"
    return base


def format_line(row):
    feature = row["feature"]
    status = row["status"]
    if status == "REVIEW":
        line = (f"REVIEW `{feature}` — {row['used_days']} Tage in {row['window']} "
                f"(eigen {row['own_days']}, andere {row['others_days']})")
    elif status == "RUNNING":
        line = (f"RUNNING `{feature}` — noch {row['days_left']} Tage, "
                f"bisher {row['own_days']} eigene Tage")
    elif status == "KEEP":
        line = (f"KEEP `{feature}` — {row['used_days']} Tage "
                f"(eigen {row['own_days']}, andere {row['others_days']})")
    elif status == "WAITING":
        line = f"WAITING `{feature}` — noch in keinem Release"
    else:
        line = f"DECIDED `{feature}` — {row['decision']}"
    if row["blind"]:
        line += " (andere Nutzer unsichtbar)"
    return line


def summary_line(rows):
    counts = {status: 0 for status in ORDER}
    for row in rows:
        counts[row["status"]] += 1
    parts = [
        f"{counts['REVIEW']} zur Prüfung",
        f"{counts['RUNNING']} laufen",
        f"{counts['KEEP']} behalten",
        f"{counts['WAITING']} warten",
        f"{counts['DECIDED']} entschieden",
    ]
    return "Ergebnis: " + ", ".join(parts) + "."


def render_markdown(summary, rows, notes):
    lines = [summary, ""]
    lines.extend(row["line"] for row in rows)
    lines.append("")
    lines.extend(notes)
    lines.append("")
    return "\n".join(lines)


def build_report(ledger_rows, today, local_days, remote_days, remote_status, local_problem,
                 git_commit, git_tag, git_date):
    graded = []
    for index, row in enumerate(ledger_rows):
        start = None
        if not row["decision"]:
            start = release_start(row, git_commit, git_tag, git_date)
        graded.append(grade_row(
            row, today, start, local_days, remote_days, remote_status == "ok"))
        graded[-1]["_i"] = index
    graded.sort(key=lambda row: (ORDER.index(row["status"]), row["_i"]))
    for row in graded:
        row["line"] = format_line(row)
        row.pop("_i", None)
    notes = [
        "„andere“ ist eine Schätzung: Telemetrie-Tageszahl minus lokale Zahl desselben Tages, ohne Nutzerkennung.",
    ]
    if local_problem:
        notes.append(local_problem)
    if remote_status == "skipped":
        notes.append("Telemetrie übersprungen (--no-remote) — nur lokale Tage.")
    elif remote_status == "unavailable":
        notes.append("Telemetrie nicht erreichbar — nur lokale Tage.")
    return summary_line(graded), graded, notes


def main(argv=None, git_commit=None, git_tag=None, git_date=None, bq=None):
    git_commit = git_commit or git_introducing_commit
    git_tag = git_tag or git_first_tag
    git_date = git_date or git_tag_date
    bq = bq or bq_feature_days

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ledger", default=DEFAULT_LEDGER, help="ledger markdown (default: plans/feature-bets.md)")
    parser.add_argument("--local", default=DEFAULT_LOCAL, help="feature-usage.json (default: the release container)")
    parser.add_argument("--today", default="", help="grade as of YYYY-MM-DD (default: the local date)")
    parser.add_argument("--no-remote", action="store_true", help="do not query BigQuery")
    parser.add_argument("--json", action="store_true", help="print machine-readable rows instead of the markdown report")
    parser.add_argument("--write", default="", help="also write <dir>/LATEST.md and <dir>/YYYY-MM-DD.md")
    args = parser.parse_args(argv)

    if args.today:
        if not DAY_RE.match(args.today):
            print(f"--today must be YYYY-MM-DD, not {args.today!r}", file=sys.stderr)
            return 2
        today = dt.date.fromisoformat(args.today)
    else:
        today = dt.date.today()

    try:
        with open(args.ledger, encoding="utf-8") as handle:
            ledger_text = handle.read()
    except OSError as exc:
        print(f"could not read ledger {args.ledger}: {exc}", file=sys.stderr)
        return 2
    ledger_rows = parse_ledger(ledger_text)
    if not ledger_rows:
        print(f"no feature rows in {args.ledger}", file=sys.stderr)
        return 2

    local_days, local_problem = load_local(args.local)
    if args.no_remote:
        remote_days, remote_status = {}, "skipped"
    else:
        fetched = bq()
        if fetched is None:
            remote_days, remote_status = {}, "unavailable"
        else:
            remote_days, remote_status = fetched, "ok"

    summary, rows, notes = build_report(
        ledger_rows, today, local_days, remote_days, remote_status, local_problem,
        git_commit, git_tag, git_date)
    markdown = render_markdown(summary, rows, notes)
    if args.write:
        os.makedirs(args.write, exist_ok=True)
        for name in ("LATEST.md", today.isoformat() + ".md"):
            with open(os.path.join(args.write, name), "w", encoding="utf-8") as handle:
                handle.write(markdown)
    if args.json:
        print(json.dumps(
            {"summary": summary, "notes": notes, "today": today.isoformat(),
             "remote": remote_status, "rows": rows},
            ensure_ascii=False, indent=2))
    else:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
