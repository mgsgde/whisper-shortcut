#!/usr/bin/env python3
"""The one place that parses and writes plans/implementer-queue.md.

Every other script goes through this. The queue is a markdown table that a human reads and
edits by hand, so it is also the single most fragile interface in the machinery: two
independent parsers would drift, and the first symptom would be a row silently skipped.

Ported from sabaki.dance's scripts/implementer/queue-edit.ts. Python rather than TypeScript
because this repo is Swift + bash and has no node toolchain; adding one for a table parser
would be a dependency nobody maintains.

    queue-edit.py list                       → JSON of every row
    queue-edit.py append --source S --proposal P --falsifier F --flag VETO --deadline D
    queue-edit.py set-flag 7 BUILD
    queue-edit.py set-status 7 'BRANCH implementer/q7-20260903'
    queue-edit.py due                        → JSON of VETO rows whose deadline has passed
    queue-edit.py veto 7                     → VETO row back to ASK (the operator's stop button)

Exit codes: 0 done, 1 nothing matched / bad input.
"""
import argparse
import json
import os
import re
import sys
from datetime import date, timedelta

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QUEUE_FILE = os.path.join(REPO_ROOT, "plans", "implementer-queue.md")

FLAGS = ("HOLD", "ASK", "VETO", "BUILD")
COLUMNS = ("num", "source", "proposal", "falsifier", "flag", "status", "deadline")
ROW_RE = re.compile(r"^\|\s*(\d+)\s*\|")


def cell(text):
    """A table cell may never contain a bare pipe — it would create a phantom column and the
    runner's awk would read the wrong field. Escape rather than reject: the proposal text comes
    from a loop's report and rejecting it there would lose the finding."""
    return re.sub(r"\s+", " ", str(text).replace("|", "\\|")).strip()


def split_row(line):
    """Split a markdown row into cells, honouring \\| escapes."""
    body = line.strip()
    body = body[1:] if body.startswith("|") else body
    body = body[:-1] if body.endswith("|") else body
    parts = re.split(r"(?<!\\)\|", body)
    return [p.replace("\\|", "|").strip() for p in parts]


def read_queue():
    with open(QUEUE_FILE, encoding="utf-8") as fh:
        return fh.read().split("\n")


def parse_rows(lines):
    rows = []
    for idx, line in enumerate(lines):
        if not ROW_RE.match(line):
            continue
        cells = split_row(line)
        row = {k: (cells[i] if i < len(cells) else "") for i, k in enumerate(COLUMNS)}
        row["num"] = int(row["num"])
        row["_line"] = idx
        rows.append(row)
    return rows


def write_queue(lines):
    with open(QUEUE_FILE, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def render(row):
    return "| " + " | ".join(cell(row.get(k, "")) for k in COLUMNS) + " |"


def cmd_list(_args):
    rows = parse_rows(read_queue())
    for r in rows:
        r.pop("_line", None)
    print(json.dumps(rows, ensure_ascii=False, indent=2))
    return 0


def cmd_append(args):
    if args.flag not in FLAGS:
        print(f"unknown flag '{args.flag}' (one of {', '.join(FLAGS)})", file=sys.stderr)
        return 1
    lines = read_queue()
    rows = parse_rows(lines)
    if not rows:
        print("queue has no rows to append after — is the table intact?", file=sys.stderr)
        return 1
    num = max(r["num"] for r in rows) + 1
    new = {
        "num": num,
        "source": args.source,
        "proposal": args.proposal,
        "falsifier": args.falsifier,
        "flag": args.flag,
        "status": "OPEN",
        "deadline": args.deadline or "",
    }
    lines.insert(rows[-1]["_line"] + 1, render(new))
    write_queue(lines)
    print(num)
    return 0


def _update(num, field, value):
    lines = read_queue()
    for row in parse_rows(lines):
        if row["num"] != num:
            continue
        row[field] = value
        lines[row["_line"]] = render(row)
        write_queue(lines)
        return 0
    print(f"no row #{num} in the queue", file=sys.stderr)
    return 1


def cmd_set_flag(args):
    if args.flag not in FLAGS:
        print(f"unknown flag '{args.flag}'", file=sys.stderr)
        return 1
    # A VETO row without a deadline is the worst state in the table: `due` skips it, so it never
    # promotes, and it was never announced either — a proposal that silently stops existing
    # while still looking queued. Refuse rather than create one.
    if args.flag == "VETO" and not re.match(r"^\d{4}-\d{2}-\d{2}", args.deadline or ""):
        print("VETO needs --deadline YYYY-MM-DD — a row without one never builds and was "
              "never announced", file=sys.stderr)
        return 1
    # A row leaving the VETO lane has no deadline any more; leaving a stale one behind would
    # make `due` re-promote a row the operator already stopped.
    rc = _update(args.num, "flag", args.flag)
    if rc == 0:
        _update(args.num, "deadline", args.deadline if args.flag == "VETO" else "")
    return rc


def cmd_set_status(args):
    return _update(args.num, "status", args.status)


def cmd_due(_args):
    """VETO rows whose window ran out. Compared as ISO strings deliberately: a deadline the
    operator extended by hand ("2026-09-10 (verlängert)") must still parse, and a lexical
    compare on the leading YYYY-MM-DD does that without a date library guessing at the rest."""
    today = date.today().isoformat()
    ripe = []
    for row in parse_rows(read_queue()):
        if row["flag"] != "VETO" or row["status"] != "OPEN":
            continue
        stamp = row["deadline"][:10]
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", stamp) and stamp <= today:
            ripe.append({"num": row["num"], "title": row["proposal"][:80], "deadline": row["deadline"]})
    print(json.dumps(ripe, ensure_ascii=False))
    return 0


def cmd_veto(args):
    """The operator's stop button. VETO → ASK, so the row survives as a decision to make
    rather than vanishing — a stopped proposal is still a finding somebody had."""
    lines = read_queue()
    for row in parse_rows(lines):
        if row["num"] != args.num:
            continue
        if row["flag"] != "VETO":
            print(f"row #{args.num} is {row['flag']}, not VETO — nothing to stop", file=sys.stderr)
            return 1
        row["flag"], row["deadline"] = "ASK", ""
        lines[row["_line"]] = render(row)
        write_queue(lines)
        print(f"row #{args.num} stopped — now ASK, it will not build unattended")
        return 0
    print(f"no row #{args.num} in the queue", file=sys.stderr)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    sub.add_parser("due").set_defaults(fn=cmd_due)

    ap_a = sub.add_parser("append")
    ap_a.add_argument("--source", required=True)
    ap_a.add_argument("--proposal", required=True)
    ap_a.add_argument("--falsifier", required=True)
    ap_a.add_argument("--flag", required=True)
    ap_a.add_argument("--deadline", default="")
    ap_a.set_defaults(fn=cmd_append)

    ap_f = sub.add_parser("set-flag")
    ap_f.add_argument("num", type=int)
    ap_f.add_argument("flag")
    ap_f.add_argument("--deadline", default="", help="required when setting VETO")
    ap_f.set_defaults(fn=cmd_set_flag)

    ap_s = sub.add_parser("set-status")
    ap_s.add_argument("num", type=int)
    ap_s.add_argument("status")
    ap_s.set_defaults(fn=cmd_set_status)

    ap_v = sub.add_parser("veto")
    ap_v.add_argument("num", type=int)
    ap_v.set_defaults(fn=cmd_veto)

    args = ap.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
