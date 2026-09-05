#!/usr/bin/env python3
"""The weekly outside view of the implementer — one mail that says what the machine is waiting
for, and who it is waiting for it.

Ported from sabaki.dance's scripts/implementer/health-report.ts (2026-08-28, extended
2026-09-05). It exists because every other signal this lane emits fires only when something
HAPPENS: the groomer mails when it files a row, the runner mails when a build lands or fails.
Nothing at all is sent when the machine goes quiet — and quiet is the failure that costs the
most, because it looks exactly like "nothing needed doing". Sabaki lost eight days and 28
proposals that way, and this repo's own queue has a row that has sat OPEN since 2026-08-20.

    python3 scripts/implementer/health-report.py [--if-due] [--dry-run] [--queue-file PATH]

    --if-due      exit quietly unless the last send is more than 6.5 days old (tick mode)
    --dry-run     print the body, send nothing, touch no stamp
    --queue-file  read the queue from here instead of plans/implementer-queue.md (the tick
                  passes an extract of origin/main when the shared checkout is busy)

Deterministic on purpose: committed state and text parsing only, no model anywhere. A health
check that can die on a network call is a health check that lies by omission.

The order of the sections is the point. What builds unattended comes first, because that is
the only part with a clock on it. Then what is genuinely waiting on a human. BLOCKED and DEFECT
come last and as counts, never as questions: BLOCKED is the evidence for the next scope stage
and DEFECT is a quality signal about the skill that wrote the proposal — the fix for it is in a
skill file, not in anyone's inbox.
"""
import argparse
import os
import re
import subprocess
import sys
import time
from datetime import date, datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
QUEUE_FILE = os.path.join(REPO_ROOT, "plans", "implementer-queue.md")
LEDGER_FILE = os.path.join(REPO_ROOT, "plans", "implementer-log.md")
BLOCK_STAMP = os.path.join(REPO_ROOT, "build", "logs", "implementer", ".blocked-since")
STATE_DIR = os.path.expanduser("~/.local/state/whispershortcut-implementer")
STAMP_FILE = os.path.join(STATE_DIR, "health-last-sent")
ARCHIVE_DIR = os.path.join(STATE_DIR, "incoming", "archive")
WINDOW_DIR = os.path.join(STATE_DIR, "merge-windows")
MAIL_TO = os.environ.get("AUDIT_MAIL_TO", "mail@magnus-goedde.de")
# Slightly under seven days, so a weekly tick pattern cannot drift into skipping a week.
DUE_AFTER_SECONDS = 6.5 * 24 * 3600
DAY = 24 * 3600


def rows_from(text):
    out = []
    for line in text.split("\n"):
        if not re.match(r"^\|\s*\d+\s*\|", line):
            continue
        cells = [c.replace("\\|", "|").strip() for c in re.split(r"(?<!\\)\|", line.strip("| \t"))]
        cells += [""] * (7 - len(cells))
        out.append({
            "num": int(cells[0]), "source": cells[1], "proposal": cells[2],
            "falsifier": cells[3], "flag": cells[4], "status": cells[5], "deadline": cells[6],
        })
    return out


def filed_on(num):
    """The date row #num first appeared, from git. The queue has no 'since' column — it is a
    table a human edits by hand, and one more column he has to keep truthful is one more way
    for it to lie. Git already knows, so ask git.

    The pickaxe string cannot collide: '| 4 |' is not a substring of '| 14 |', and a cell may
    never contain a bare pipe (queue-edit.py escapes them)."""
    try:
        out = subprocess.run(
            ["git", "log", "--format=%ad", "--date=short", "-S", f"| {num} |", "--",
             "plans/implementer-queue.md"],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=30,
        ).stdout.strip().split("\n")
        return out[-1] if out and out[-1] else ""
    except (subprocess.SubprocessError, OSError):
        return ""


def age_days(iso):
    try:
        return (date.today() - date.fromisoformat(iso[:10])).days
    except ValueError:
        return None


def since(iso):
    d = age_days(iso)
    return f"{d}d" if d is not None else "?"


def group_counts(rows):
    """Source strings carry a run date and sometimes a class; the loop's NAME is the stable
    part, and it is the part a reader acts on. Everything up to the first date or bullet."""
    counts = {}
    for row in rows:
        name = re.split(r"[·(]|\d{4}-\d{2}-\d{2}", row["source"])[0].strip() or "(unattributed)"
        counts[name] = counts.get(name, 0) + 1
    return sorted(counts.items(), key=lambda kv: -kv[1])


def proposal_flow():
    """How many proposals reached the groomer lately. A lane whose loops stopped emitting looks
    identical, from the queue alone, to a lane where everything is fine."""
    if not os.path.isdir(ARCHIVE_DIR):
        return None, 0
    now = time.time()
    ages = [now - os.path.getmtime(os.path.join(ARCHIVE_DIR, f))
            for f in os.listdir(ARCHIVE_DIR) if f.endswith(".json")]
    if not ages:
        return None, 0
    return min(ages) / DAY, sum(1 for a in ages if a <= 7 * DAY)


def merge_windows():
    """The open merge windows, read from the state dir rather than the queue. They cannot be in
    the queue: the runner writes its bookkeeping on the branch, so main's copy of a row still
    says BUILD/OPEN until the merge it is waiting for actually happens."""
    out = []
    if not os.path.isdir(WINDOW_DIR):
        return out
    for name in sorted(os.listdir(WINDOW_DIR)):
        if not name.endswith(".env"):
            continue
        fields = {}
        for line in open(os.path.join(WINDOW_DIR, name), encoding="utf-8"):
            key, _, value = line.strip().partition("=")
            fields[key] = value
        out.append(fields)
    return out


def build_body(rows):
    veto = [r for r in rows if r["flag"] == "VETO" and r["status"] == "OPEN"]
    build = [r for r in rows if r["flag"] == "BUILD" and r["status"] == "OPEN"]
    parked = [r for r in rows if r["status"] == "DEFERRED"]
    ask = [r for r in rows if r["flag"] == "ASK" and r["status"] == "OPEN"]
    blocked = [r for r in rows if r["status"] == "BLOCKED"]
    defect = [r for r in rows if r["status"] == "DEFECT"]
    running = [r for r in rows if r["status"].startswith(("BRANCH", "PR "))]

    lines = []
    windows = merge_windows()
    if windows:
        lines += ["## Merging into main on silence — these have a clock on them", ""]
        for w in windows:
            num = w.get("QUEUE_NUM", "?")
            if w.get("VETOED"):
                lines.append(f"#{num} — STOPPED by you, the next tick closes the window and "
                             f"keeps branch {w.get('BRANCH', '?')}")
                continue
            lines.append(f"#{num} — {w.get('BRANCH', '?')}")
            lines.append(f"    merges on {w.get('DEADLINE') or '(no deadline)'} unless stopped:  "
                         f"bash scripts/implementer/veto.sh {num}")
        lines += ["",
                  "  A merge is not a release: create-release.sh, the App Store submission and",
                  "  the parent repo's submodule pointer are all still yours.", ""]
    if veto:
        lines += ["## Building on silence — these have a clock on them", ""]
        for r in veto:
            lines.append(f"#{r['num']} — {r['proposal'][:100]}")
            lines.append(f"    builds on {r['deadline'] or '(NO DEADLINE — it never will)'} "
                         f"unless stopped:  bash scripts/implementer/veto.sh {r['num']}")
        lines.append("")
    if build:
        lines += ["## Released, waiting for the next tick", ""]
        lines += [f"#{r['num']} — {r['proposal'][:100]}" for r in build]
        lines.append("")
    if running:
        lines += ["## In flight", ""]
        lines += [f"#{r['num']} — {r['status']}  ({r['proposal'][:70]})" for r in running]
        lines.append("")

    lines += ["## Waiting on you", ""]
    if ask:
        for r in ask:
            filed = filed_on(r["num"])
            lines.append(f"#{r['num']} — {r['proposal'][:100]}")
            lines.append(f"    open {since(filed) if filed else '?'} · "
                         f"keep it: bash scripts/implementer/keep.sh {r['num']} [BUILD|VETO]")
    else:
        lines.append("Nothing. Every open row is waiting for the machine, not for you.")
    lines.append("")

    # Backpressure has to have a number, or a cap that has become the bottleneck is
    # indistinguishable from a lane with nothing to do.
    lines += ["## Not waiting on you", ""]
    lines.append(f"{len(parked)} parked (DEFERRED) — cleared every gate, waiting for a build "
                 f"slot. A number that keeps growing means the in-flight cap is the bottleneck.")
    if blocked:
        detail = ", ".join(f"{n} x{c}" for n, c in group_counts(blocked))
        lines.append(f"{len(blocked)} BLOCKED — out of IMPLEMENTER_SCOPE, so the runner cannot "
                     f"reach them: {detail}. This is the evidence for widening the scope, not a "
                     f"decision to make row by row.")
    if defect:
        detail = ", ".join(f"{n} x{c}" for n, c in group_counts(defect))
        lines.append(f"{len(defect)} DEFECT — the proposal could not be read (class or "
                     f"falsifier): {detail}. The fix belongs in that loop's skill file.")
    lines.append("")

    lines += ["## Is anything still arriving", ""]
    newest, last_week = proposal_flow()
    if newest is None:
        lines.append("No proposal file has ever reached the groomer's archive. Either no loop "
                     "emits one yet, or IMPLEMENTER_INCOMING_DIR is not where they land.")
    else:
        lines.append(f"{last_week} proposal(s) in the last 7 days · newest {newest:.1f} days old.")
    if os.path.exists(BLOCK_STAMP):
        try:
            hours = int((time.time() - int(open(BLOCK_STAMP).read().strip())) / 3600)
            lines.append(f"Builds have been paused {hours}h — the shared checkout is not on "
                         f"main. Grooming is unaffected; released rows wait.")
        except (ValueError, OSError):
            pass
    if os.path.exists(LEDGER_FILE):
        written = datetime.fromtimestamp(os.path.getmtime(LEDGER_FILE)).date().isoformat()
        lines.append(f"Ledger plans/implementer-log.md last written {since(written)} ago.")
    lines += ["", "Queue: plans/implementer-queue.md · architecture: plans/agent-loops.md"]

    on_a_clock = len(veto) + len([w for w in windows if not w.get("VETOED")])
    subject = (f"WhisperShortcut implementer — {on_a_clock} on a clock, {len(ask)} on your desk, "
               f"{len(parked)} parked")
    return subject, "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--if-due", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--queue-file", default=QUEUE_FILE)
    args = ap.parse_args()

    if args.if_due and os.path.exists(STAMP_FILE):
        if time.time() - os.path.getmtime(STAMP_FILE) < DUE_AFTER_SECONDS:
            return 0

    try:
        text = open(args.queue_file, encoding="utf-8").read()
    except OSError as exc:
        print(f"cannot read the queue at {args.queue_file}: {exc}", file=sys.stderr)
        return 1
    subject, body = build_body(rows_from(text))

    if args.dry_run:
        print(subject)
        print()
        print(body)
        return 0

    tmp = os.path.join("/tmp", f"ws-implementer-health-{os.getpid()}.md")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
    try:
        rc = subprocess.run(
            [sys.executable, os.path.join(REPO_ROOT, "scripts", "send-report-mail.py"),
             "--to", MAIL_TO, "--subject", subject, "--body-file", tmp]
        ).returncode
    finally:
        os.unlink(tmp)
    if rc != 0:
        # NOT stamped: a mail that failed must be retried, and a stamp would hide the failure
        # for a week — the exact silence this report exists to break.
        print("could not send the health mail — NOT stamping, so the next tick retries",
              file=sys.stderr)
        return 1
    os.makedirs(STATE_DIR, exist_ok=True)
    open(STAMP_FILE, "w").write(datetime.now().isoformat())
    print(f"health mail sent: {subject}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
