#!/usr/bin/env python3
"""Detect CI runs whose jobs were cancelled by a GitHub hosted-runner outage.

On 2026-11-20 GitHub had no macOS hosted runners. Jobs were cancelled with a check-run annotation
"The job was not acquired by Runner of type hosted even after multiple attempts"; the run's
conclusion became "failure" and the merge train read main as red. The train asks this helper
whether a run lost its runner (then it re-runs the failed jobs) or really failed.

    runner_outage.py check <repo> <run_id>     prints "rerun <attempt>" or "red <attempt>"

Any gh or JSON error prints "red 0" and exits 0 (the old behaviour). Stdlib only.
"""
import json
import os
import re
import subprocess
import sys

OUTAGE_MARKER = "was not acquired by Runner"
MAX_RERUNS = 2
NON_RED = {"success", "skipped", "neutral", "cancelled"}
RUN_ID_RE = re.compile(r"/actions/runs/(\d+)")


def is_runner_outage(jobs):
    """jobs: list of {"conclusion": str|None, "annotations": [messages]}."""
    if not jobs:
        return False
    cancelled = [j for j in jobs if j.get("conclusion") == "cancelled"]
    if not cancelled:
        return False
    if any(j.get("conclusion") not in NON_RED for j in jobs):
        return False
    return all(
        any(OUTAGE_MARKER in (m or "") for m in (j.get("annotations") or []))
        for j in cancelled
    )


def decide(outage, attempt, max_reruns):
    """attempt 1 is the original run, so max_reruns=2 allows re-running attempts 1 and 2."""
    return "rerun" if outage and attempt <= max_reruns else "red"


def run_ids_from_rollup(entries):
    ids = set()
    for e in entries or []:
        if e.get("__typename") == "StatusContext":
            continue
        if e.get("status") != "COMPLETED" or e.get("conclusion") != "CANCELLED":
            continue
        m = RUN_ID_RE.search(e.get("detailsUrl") or "")
        if m:
            ids.add(int(m.group(1)))
    return sorted(ids)


def _gh_json(path):
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True,
                         text=True, timeout=60)
    return json.loads(out.stdout)


def fetch(repo, run_id):
    """Returns (run_attempt, jobs) for the latest attempt; annotations only for cancelled jobs."""
    run = _gh_json(f"repos/{repo}/actions/runs/{run_id}")
    attempt = int(run.get("run_attempt") or 0)
    data = _gh_json(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    jobs = []
    for j in data.get("jobs") or []:
        conclusion = j.get("conclusion")
        messages = []
        if conclusion == "cancelled":
            ann = _gh_json(f"repos/{repo}/check-runs/{j['id']}/annotations")
            messages = [a.get("message") or "" for a in ann or []]
        jobs.append({"conclusion": conclusion, "annotations": messages})
    return attempt, jobs


def check(repo, run_id, max_reruns=MAX_RERUNS, fetch_fn=fetch):
    try:
        attempt, jobs = fetch_fn(repo, run_id)
    except Exception:
        return "red 0"
    return f"{decide(is_runner_outage(jobs), attempt, max_reruns)} {attempt}"


def main(argv=None, fetch_fn=fetch, out=None):
    argv = sys.argv[1:] if argv is None else argv
    out = out or sys.stdout
    if len(argv) != 3 or argv[0] != "check":
        print("usage: runner_outage.py check <repo> <run_id>", file=sys.stderr)
        return 2
    try:
        max_reruns = int(os.environ.get("MERGE_TRAIN_MAX_RERUNS", MAX_RERUNS))
    except ValueError:
        max_reruns = MAX_RERUNS
    print(check(argv[1], argv[2], max_reruns, fetch_fn), file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
