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

An ASK row then says WHO it is waiting for, in its status (the table in queue-edit.py):
`OPEN` is a human's judgement, `BLOCKED` is reach the runner does not have, `DEFECT` is a
proposal this file could not read. Only OPEN belongs on the operator's desk — being asked to
rule on a scope allowlist is not a decision, it is plumbing wearing a question mark.

And the in-flight cap parks rather than demotes: a proposal that cleared every gate and only
met a full queue keeps the lane it earned, as `DEFERRED`, and the release sweep at the top of
each run gives it the next free slot. A rate limit that throws its overflow away is not a rate
limit.

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


def decide_lane(proposal, existing, gaps, in_flight):
    """Return (lane, park, reason). Lookups and regexes only — never a judgement call.

    `lane` is what the proposal earned; `park` is who it is then waiting for. The two are
    orthogonal on purpose: a capped row keeps its lane and waits for a slot, and a row nobody
    can read is not a question for the operator however good its finding may be."""
    cls = (proposal.get("class") or "").strip()
    title = proposal.get("title") or proposal.get("proposal") or ""

    # A proposal this file cannot read is a defect in the skill that wrote it, not a question
    # for the operator. It parks in DEFECT, where the loop can re-file it corrected — the dedup
    # below lets a DEFECT row be superseded, and only that status.
    if not (proposal.get("falsifier") or "").strip():
        return "ASK", "DEFECT", "no falsifier — a row nothing can grade may not build unattended"

    # Dedupe against what the queue actually stores, which is the proposal line. Comparing the
    # title against it compares two different fields, and a short title never prefixes a longer
    # proposal — so the check silently never fired. Both directions, because a loop may shorten
    # or lengthen its wording between runs; both fields, because either may be the stable one.
    # One exception, and only one: a row parked in DEFECT is not a decision and not an outcome
    # — it is a proposal the machine refused to read. Blocking on it would mean a loop that
    # once wrote a bad falsifier can NEVER file that finding again, however well it words it
    # the second time. Everything else in the queue still blocks, which is what this check is
    # for: re-proposing a written-off finding is what makes a queue useless.
    for candidate in (proposal.get("proposal"), title):
        key = normalise(candidate)[:60]
        if not key:
            continue
        for row in existing:
            stored = normalise(row["proposal"])
            if stored.startswith(key) or key.startswith(stored[:60]):
                if row["status"] == "DEFECT":
                    continue
                return "SKIP", "OPEN", f"already in the queue as #{row['num']} ({row['status']})"

    paths = proposal.get("paths") or []
    outside = [p for p in paths if not p.startswith(SCOPE_PREFIXES)]
    if outside:
        # Out of IMPLEMENTER_SCOPE is a missing hand, not a missing decision. It parks in
        # BLOCKED, where it is the evidence for the next scope stage rather than a question the
        # operator can only answer by widening an allowlist he was not asked about.
        return "ASK", "BLOCKED", f"touches {outside[0]} — outside IMPLEMENTER_SCOPE=app"

    if cls in AUTO_CLASSES:
        gap = proposal.get("gap")
        if not isinstance(gap, int) or gap not in gaps:
            return "ASK", "OPEN", "instrumentation without an OPEN row in plans/instrumentation-gaps.md"
        lane, earned = "BUILD", f"closes instrumentation gap #{gap} — red→green is checkable"
    elif cls in VETO_WINDOW_DAYS:
        if not VETO_LANE_ENABLED:
            return "ASK", "OPEN", "VETO lane disabled (IMPLEMENTER_VETO_LANE=0)"
        days = VETO_WINDOW_DAYS[cls]
        lane = "VETO"
        earned = f"reversible, in scope, falsifier gradeable — builds in {days}d unless stopped"
    else:
        return "ASK", "DEFECT", f"class '{cls or '(none)'}' has no automatic gate"

    # The cap comes last, so a parked row is always one that would otherwise have qualified —
    # and it keeps the lane it earned. It used to be written as ASK "for the operator to pull
    # forward", which reads well and works out badly: the row loses the gate it passed and
    # waits on a desk for a decision that was already made by a deterministic rule.
    if in_flight >= MAX_INFLIGHT:
        return lane, "DEFERRED", f"{MAX_INFLIGHT} in-flight rows already — qualified, parked"
    return lane, "OPEN", earned


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

    # --- Release sweep: parked rows get the free slots before new proposals do ---------------
    # Computed first, and its rows count against the cap below, so a row that has already
    # waited does not lose its place to a proposal filed this morning. Oldest first, by queue
    # number — the order they qualified in.
    parked = sorted((r for r in existing if r["status"] == "DEFERRED"), key=lambda r: r["num"])
    releasing = parked[: max(0, MAX_INFLIGHT - len(open_auto))]
    auto_so_far = len(open_auto) + len(releasing)

    # A VETO row whose deadline is missing or unreadable promotes never and was announced
    # never — it just sits there looking queued. `due` cannot see it, so nothing else would
    # ever mention it again. Say so every tick.
    for row in open_auto:
        if row["flag"] == "VETO" and not re.match(r"^\d{4}-\d{2}-\d{2}", row["deadline"]):
            log(f"WARN: row #{row['num']} is VETO with no readable deadline "
                f"({row['deadline']!r}) — it will never build. Give it one or flag it ASK.")

    gaps = open_gap_numbers()
    proposals = load_proposals(files)
    log(f"{len(proposals)} proposal(s) from {len(files)} file(s) · {len(open_auto)} in flight · "
        f"{len(parked)} parked · cap {MAX_INFLIGHT}")

    announcements, filed = [], []
    for path, proposal in proposals:
        lane, park, reason = decide_lane(proposal, existing, gaps, auto_so_far)
        title = proposal.get("title") or proposal.get("proposal") or "(no title)"
        icon = "⏸" if park == "DEFERRED" else {"BUILD": "🟢", "VETO": "🔵", "ASK": "🟡", "SKIP": "⚪️"}[lane]
        label = lane if park == "OPEN" else f"{lane}·{park}"
        log(f"{icon} {label}: {title[:70]} — {reason}")
        if lane == "SKIP" or args.dry_run:
            continue

        deadline = ""
        if lane == "VETO" and park == "OPEN":
            days = VETO_WINDOW_DAYS[proposal["class"]]
            deadline = (date.today() + timedelta(days=days)).isoformat()
        # A parked row carries its class in Source, because the proposal file is archived this
        # same run and the release sweep still has to size the window the row never got.
        source = proposal.get("source", "loop proposal")
        if park == "DEFERRED":
            source = f"{source} · class: {proposal.get('class', '')}"

        num = queue_edit(
            "append",
            "--source", source,
            "--proposal", proposal.get("proposal") or title,
            "--falsifier", proposal.get("falsifier", ""),
            "--flag", lane,
            "--deadline", deadline,
            "--status", park,
        )
        filed.append((num, label, title))
        # Re-read so the next proposal's duplicate check sees the row we just wrote.
        existing = json.loads(queue_edit("list"))
        # A parked row consumes no slot this run — that is the whole point of parking it.
        if park == "OPEN" and lane in ("BUILD", "VETO"):
            auto_so_far += 1
        if lane == "VETO" and park == "OPEN":
            announcements.append((num, title, deadline, reason))

    # Release the parked rows into the slots that came free. A VETO row's window starts HERE,
    # not when it was filed: a window the operator could not have acted on is not a window, and
    # it would already have run out by the time the row became real.
    released = []
    if not args.dry_run:
        for row in releasing:
            if row["flag"] == "VETO":
                match = re.search(r"· class: ([a-z-]+)", row["source"])
                days = VETO_WINDOW_DAYS.get(match.group(1) if match else "",
                                            max(VETO_WINDOW_DAYS.values()))
                deadline = (date.today() + timedelta(days=days)).isoformat()
                queue_edit("set-flag", str(row["num"]), "VETO", "--deadline", deadline)
                released.append((row["num"], row["proposal"][:80], deadline))
            queue_edit("set-status", str(row["num"]), "OPEN")
            log(f"⏵ released #{row['num']} from parking — a build slot came free")

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

    if announcements or ripe or released:
        lines = []
        if released:
            # Only the VETO releases need announcing: a released BUILD row was decided by a
            # deterministic gate when it was filed, and saying so again is the weekly's job.
            lines += [
                "A build slot came free, so these parked rows became real. They cleared every",
                "gate when they were filed and were only waiting for capacity:",
                "",
                *[f"#{n} — {t}\n    builds on {d} unless stopped" for n, t, d in released],
                "",
            ]
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
            f"WhisperShortcut implementer — {len(announcements) + len(released)} to veto, "
            f"{len(ripe)} promoted",
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
    if (filed or ripe or released) and not args.dry_run:
        subprocess.run(
            ["git", "commit", "-m",
             f"Groom implementer queue: {len(filed)} filed, {len(released)} released, "
             f"{len(ripe)} promoted\n\n"
             "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>",
             "--", "plans/implementer-queue.md"],
            cwd=REPO_ROOT, capture_output=True, check=False,
        )
    log(f"done — {len(filed)} filed, {len(released)} released, {len(ripe)} promoted")


if __name__ == "__main__":
    main()
