#!/usr/bin/env python3
"""The groomer — turns loop proposals into queue rows.

Ported from sabaki.dance's scripts/implementer/groom-queue.ts (design 2026-08-19 §6,
VETO lane 2026-08-28 §4). Architecture: plans/agent-loops.md.

    python3 scripts/implementer/groom-queue.py --dry-run
    python3 scripts/implementer/groom-queue.py --from /path/to/proposals.json

This is the piece that decides what may be built without a human, so the one property that
matters is that it contains NO JUDGEMENT. Every rule below is a lookup or a regex against
committed state; there is no model in this file and there must never be one. A loop says what
its proposal IS (`class`); this decides what that class is allowed to do, and only ever trusts
classes an existing gate can judge:

    instrumentation → must name an OPEN row in plans/instrumentation-gaps.md. Blast radius is
                      one logged field, and the policy already ranks these above features.

Everything else either gets a veto window (reversible, in scope, falsifier a later run can
grade) or lands in ASK. Nothing is ever dropped: a proposal the groomer cannot justify becomes
a row you can flip, not a finding that evaporates.

Input: one JSON file per loop run in $IMPLEMENTER_INCOMING_DIR, each holding an object or a
list of objects:

    {"source": "model-audit 2026-09-03", "title": "…", "proposal": "…",
     "falsifier": "…", "class": "model-migration", "paths": ["WhisperShortcut/…"],
     "gap": 8}

Consumed files are moved to `<incoming>/archive/` — a proposal read twice would file the row
twice, and a proposal deleted on failure would be lost.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import date, timedelta

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
QUEUE_EDIT = os.path.join(SCRIPT_DIR, "queue-edit.py")
GAPS_FILE = os.path.join(REPO_ROOT, "plans", "instrumentation-gaps.md")
DEFAULT_INCOMING = os.path.expanduser("~/.local/state/whispershortcut-implementer/incoming")

MAIL_TO = os.environ.get("AUDIT_MAIL_TO", "mail@magnus-goedde.de")

# Classes an existing deterministic gate can judge — these build with no announcement at all.
AUTO_CLASSES = ("instrumentation",)

# Classes that build on SILENCE. They have no red→green checker the way an instrumentation row
# has, but they are reversible, in scope, and carry a falsifier a later loop run can read — so
# the honest gate is your chance to object, not your obligation to approve.
#
# The number is the veto window in days. It is per class because the blast radius differs, not
# because your attention does: a copy change is a word, a model migration changes what every
# dictation is sent to.
VETO_WINDOW_DAYS = {
    "copy": int(os.environ.get("IMPLEMENTER_VETO_DAYS_COPY", 1)),
    "ui": int(os.environ.get("IMPLEMENTER_VETO_DAYS_UI", 2)),
    "bug-fix": int(os.environ.get("IMPLEMENTER_VETO_DAYS_BUGFIX", 2)),
    "model-migration": int(os.environ.get("IMPLEMENTER_VETO_DAYS_MODEL", 3)),
}
VETO_LANE_ENABLED = os.environ.get("IMPLEMENTER_VETO_LANE", "1") == "1"

# Both auto lanes count against this. A VETO row is a build that has not started yet, so a
# groomer that filed ten of them would have queued ten unattended builds, cap or no cap.
MAX_INFLIGHT = int(os.environ.get("IMPLEMENTER_MAX_INFLIGHT", 3))

# Same allowlist the runner enforces (IMPLEMENTER_SCOPE=app). Checked here too so a
# hopeless row is filed as ASK rather than starting a build that dies on the scope gate.
SCOPE_PREFIXES = ("WhisperShortcut/", "WhisperShortcutTests/", "plans/implementer-")


def log(msg):
    print(f"[groom] {msg}", file=sys.stderr)


def queue_edit(*args):
    return subprocess.run(
        [sys.executable, QUEUE_EDIT, *args],
        cwd=REPO_ROOT, capture_output=True, text=True, check=True,
    ).stdout.strip()


def open_gap_numbers():
    """Gap rows that are still OPEN. `| # | Gap | Blinds | Status | Notes |` — status is cell 4.

    Positional, and safe to be: a bare pipe inside one of the first four cells would break the
    table for the human reader too, so the register cannot contain one. Rows whose Notes carry
    extra pipes (gap #7 does) parse fine — the surplus lands past the status column."""
    if not os.path.exists(GAPS_FILE):
        return set()
    nums = set()
    for line in open(GAPS_FILE, encoding="utf-8"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 4 and cells[0].isdigit() and cells[3].upper() == "OPEN":
            nums.add(int(cells[0]))
    return nums


def normalise(text):
    return re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()


def decide_lane(proposal, existing, gaps, auto_so_far):
    """Return (lane, reason). Lookups and regexes only — never a judgement call."""
    cls = (proposal.get("class") or "").strip()
    title = proposal.get("title") or proposal.get("proposal") or ""

    if not (proposal.get("falsifier") or "").strip():
        return "ASK", "no falsifier — a row nothing can grade may not build unattended"

    # Dedupe against what the queue actually stores, which is the proposal line. Comparing the
    # title against it compares two different fields, and a short title never prefixes a longer
    # proposal — so the check silently never fired. Both directions, because a loop may shorten
    # or lengthen its wording between runs; both fields, because either may be the stable one.
    for candidate in (proposal.get("proposal"), title):
        key = normalise(candidate)[:60]
        if not key:
            continue
        for row in existing:
            stored = normalise(row["proposal"])
            if stored.startswith(key) or key.startswith(stored[:60]):
                return "SKIP", f"already in the queue as #{row['num']}"

    paths = proposal.get("paths") or []
    outside = [p for p in paths if not p.startswith(SCOPE_PREFIXES)]
    if outside:
        return "ASK", f"touches {outside[0]} — outside IMPLEMENTER_SCOPE=app"

    if cls in AUTO_CLASSES:
        gap = proposal.get("gap")
        if not isinstance(gap, int) or gap not in gaps:
            return "ASK", "instrumentation without an OPEN row in plans/instrumentation-gaps.md"
        if auto_so_far >= MAX_INFLIGHT:
            return "ASK", f"in-flight cap reached ({MAX_INFLIGHT})"
        return "BUILD", f"closes instrumentation gap #{gap} — red→green is checkable"

    if cls in VETO_WINDOW_DAYS:
        if not VETO_LANE_ENABLED:
            return "ASK", "VETO lane disabled (IMPLEMENTER_VETO_LANE=0)"
        if auto_so_far >= MAX_INFLIGHT:
            return "ASK", f"in-flight cap reached ({MAX_INFLIGHT})"
        days = VETO_WINDOW_DAYS[cls]
        return "VETO", f"reversible, in scope, falsifier gradeable — builds in {days}d unless stopped"

    return "ASK", f"class '{cls or '(none)'}' has no automatic gate"


def load_proposals(paths):
    out = []
    for path in paths:
        try:
            data = json.load(open(path, encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            log(f"WARN: unreadable proposal file {path}: {exc}")
            continue
        for item in (data if isinstance(data, list) else [data]):
            if isinstance(item, dict):
                out.append((path, item))
    return out


def send_mail(subject, body, no_mail=False):
    if no_mail:
        log("--no-mail: NOT sending the announcement below. This is a test run only.")
        log(f"  subject: {subject}")
        for line in body.splitlines():
            log(f"  | {line}")
        return
    helper = os.path.join(REPO_ROOT, "scripts", "send-report-mail.py")
    tmp = os.path.join("/tmp", f"groom-announce-{os.getpid()}.md")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
    try:
        rc = subprocess.run(
            [sys.executable, helper, "--to", MAIL_TO, "--subject", subject, "--body-file", tmp]
        ).returncode
        if rc != 0:
            # A VETO row that is never announced is not a veto window — it is an unattended
            # build the operator was never told about. Say so loudly rather than proceeding
            # quietly; the notification is the fallback channel the other jobs already use.
            log("WARN: could not mail the VETO announcement — falling back to a notification")
            subprocess.run(
                ["osascript", "-e",
                 f'display notification "{len(body.splitlines())} lines — see the queue" '
                 f'with title "{subject}"'],
                capture_output=True,
            )
    finally:
        os.unlink(tmp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--from", dest="src", action="append", default=[])
    # Testing only. A VETO row that is not announced is not a veto window — it is an unattended
    # build nobody was told about — so this prints the announcement instead of suppressing it,
    # and says so. Never use it from tick.sh.
    ap.add_argument("--no-mail", action="store_true",
                    help="print announcements instead of mailing them (testing)")
    args = ap.parse_args()

    incoming = os.environ.get("IMPLEMENTER_INCOMING_DIR", DEFAULT_INCOMING)
    files = list(args.src)
    if not files and os.path.isdir(incoming):
        files = sorted(
            os.path.join(incoming, f) for f in os.listdir(incoming) if f.endswith(".json")
        )

    existing = json.loads(queue_edit("list"))
    open_auto = [r for r in existing if r["flag"] in ("BUILD", "VETO") and r["status"] == "OPEN"]
    auto_so_far = len(open_auto)

    # A VETO row whose deadline is missing or unreadable promotes never and was announced
    # never — it just sits there looking queued. `due` cannot see it, so nothing else would
    # ever mention it again. Say so every tick.
    for row in open_auto:
        if row["flag"] == "VETO" and not re.match(r"^\d{4}-\d{2}-\d{2}", row["deadline"]):
            log(f"WARN: row #{row['num']} is VETO with no readable deadline "
                f"({row['deadline']!r}) — it will never build. Give it one or flag it ASK.")

    gaps = open_gap_numbers()
    proposals = load_proposals(files)
    log(f"{len(proposals)} proposal(s) from {len(files)} file(s) · {auto_so_far} already in flight")

    announcements, filed = [], []
    for path, proposal in proposals:
        lane, reason = decide_lane(proposal, existing, gaps, auto_so_far)
        title = proposal.get("title") or proposal.get("proposal") or "(no title)"
        icon = {"BUILD": "🟢", "VETO": "🔵", "ASK": "🟡", "SKIP": "⚪️"}[lane]
        log(f"{icon} {lane}: {title[:70]} — {reason}")
        if lane == "SKIP" or args.dry_run:
            continue

        deadline = ""
        if lane == "VETO":
            days = VETO_WINDOW_DAYS[proposal["class"]]
            deadline = (date.today() + timedelta(days=days)).isoformat()

        num = queue_edit(
            "append",
            "--source", proposal.get("source", "loop proposal"),
            "--proposal", proposal.get("proposal") or title,
            "--falsifier", proposal.get("falsifier", ""),
            "--flag", lane,
            "--deadline", deadline,
        )
        filed.append((num, lane, title))
        # Re-read so the next proposal's duplicate check sees the row we just wrote.
        existing = json.loads(queue_edit("list"))
        if lane in ("BUILD", "VETO"):
            auto_so_far += 1
        if lane == "VETO":
            announcements.append((num, title, deadline, reason))

    # Silence promotes. A row whose window ran out becomes BUILD; a row you stopped is ASK by
    # now and `due` never sees it again.
    ripe = json.loads(queue_edit("due")) if not args.dry_run else []
    for row in ripe:
        queue_edit("set-flag", str(row["num"]), "BUILD")
        log(f"🟢 promoted #{row['num']} — veto window ended {row['deadline']}")

    if not args.dry_run:
        archive = os.path.join(incoming, "archive")
        os.makedirs(archive, exist_ok=True)
        for path in {p for p, _ in proposals}:
            if os.path.dirname(path) == incoming:
                shutil.move(path, os.path.join(archive, os.path.basename(path)))

    if announcements or ripe:
        lines = []
        if announcements:
            lines += [
                "The implementer filed these in the VETO lane. You do not have to do anything —",
                "they build on their deadline unless you stop them:",
                "",
                *[f"#{n} — {t}\n    builds on {d} unless stopped · {r}" for n, t, d, r in announcements],
                "",
                "Stop one with:  bash scripts/implementer/veto.sh <#>",
                "",
            ]
        if ripe:
            lines += [
                "Promoted to BUILD — their veto window ran out:",
                *[f"#{r['num']} — {r['title']} (window ended {r['deadline']})" for r in ripe],
                "",
            ]
        lines.append("Queue: plans/implementer-queue.md")
        send_mail(
            f"WhisperShortcut implementer — {len(announcements)} to veto, {len(ripe)} promoted",
            "\n".join(lines),
            no_mail=args.no_mail,
        )

    # Commit on main: a proposal filed on a branch nobody merges is a proposal nobody sees.
    #
    # The pathspec form is not a style choice. `git add <file>` followed by a bare `git commit`
    # commits everything ALREADY STAGED — so a tick firing while the operator had staged work
    # in the shared checkout would sweep that work into a commit titled "Groom implementer
    # queue". Naming the path makes the commit contain exactly this file, whatever the index
    # holds.
    if (filed or ripe) and not args.dry_run:
        subprocess.run(
            ["git", "commit", "-m",
             f"Groom implementer queue: {len(filed)} filed, {len(ripe)} promoted\n\n"
             "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>",
             "--", "plans/implementer-queue.md"],
            cwd=REPO_ROOT, capture_output=True, check=False,
        )
    log(f"done — {len(filed)} filed, {len(ripe)} promoted")


if __name__ == "__main__":
    main()
