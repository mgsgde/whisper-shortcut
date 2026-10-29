#!/usr/bin/env python3
"""Grader cases for scripts/feature-bets.py. Git and BigQuery are injected."""
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TODAY = "2026-10-29"

LEDGER = """\
# Fixture

| Feature (`TelemetryFeature`) | What the user does | Added | Window | Decision |
| --- | --- | --- | --- | --- |
| `waitingFeature` | not released | next | 21d | |
| `runningFeature` | still in the window | next | 21d | |
| `keepOwn` | used on this Mac | next | 21d | |
| `keepOthers` | used elsewhere | next | 21d | |
| `reviewFeature` | barely used | next | 21d | |
| `decidedFeature` | kept by hand | next | 21d | keep (2026-10-01, bleibt) |
| `tagFeature` | shipped as a named tag | v8.70 | 21d | |
"""

# runningFeature's release is 2026-10-20 (window ends 2026-11-10, still open on TODAY).
# The September features shipped 2026-09-01 (window ends 2026-09-22, closed).
# tagFeature's Added cell is the tag; its date is 2026-08-01 (closed).
COMMITS = {
    "waitingFeature": "aaa",
    "runningFeature": "bbb",
    "keepOwn": "ccc",
    "keepOthers": "ddd",
    "reviewFeature": "eee",
    "decidedFeature": "fff",
}
TAGS = {
    "bbb": "v9.1",
    "ccc": "v9.0",
    "ddd": "v9.0",
    "eee": "v9.0",
    "fff": "v9.0",
}
DATES = {
    "v9.1": "2026-10-20T08:00:00+01:00",
    "v9.0": "2026-09-01T08:00:00+02:00",
    "v8.70": "2026-08-01T08:00:00+02:00",
}

LOCAL = {
    "since": 0,
    "entries": {
        "runningFeature": {"count": 3, "days": {"2026-10-21": 2, "2026-10-29": 1, "2026-10-19": 9}},
        "keepOwn": {"count": 6, "days": {
            "2026-08-31": 9, "2026-09-01": 1, "2026-09-10": 4, "2026-09-21": 1,
            "2026-09-22": 9, "2026-09-11": 0,
        }},
        "reviewFeature": {"count": 4, "days": {"2026-09-01": 3, "2026-09-02": 1}},
        "tagFeature": {"count": 3, "days": {"2026-08-01": 1, "2026-08-02": 1, "2026-08-03": 1}},
    },
}

# reviewFeature: remote matches local on the two own days (difference 0) and exceeds it on one more.
REMOTE = {
    "keepOwn": {"2026-09-01": 1, "2026-09-10": 4, "2026-09-21": 1},
    "keepOthers": {"2026-09-02": 2, "2026-09-03": 1, "2026-09-04": 5, "2026-09-22": 9},
    "reviewFeature": {"2026-09-01": 3, "2026-09-02": 1, "2026-09-08": 2},
}


def load_module():
    spec = importlib.util.spec_from_file_location("feature_bets", ROOT / "feature-bets.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fake_commit(feature):
    if feature == "tagFeature":
        raise AssertionError("an Added tag must be used directly, not looked up")
    return COMMITS.get(feature)


def fake_tag(sha):
    return TAGS.get(sha)


def fake_date(tag):
    return DATES[tag]


class FeatureBetsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fb = load_module()

    def grade(self, local_path, remote, no_remote=False, write=None):
        argv = ["--ledger", self.ledger, "--local", local_path, "--today", TODAY, "--json"]
        if no_remote:
            argv.append("--no-remote")
        if write:
            argv.extend(["--write", write])
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = self.fb.main(
                argv,
                git_commit=fake_commit,
                git_tag=fake_tag,
                git_date=fake_date,
                bq=(lambda: remote),
            )
        self.assertEqual(code, 0, buffer.getvalue())
        return json.loads(buffer.getvalue())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = os.path.join(self.tmp.name, "ledger.md")
        self.local = os.path.join(self.tmp.name, "feature-usage.json")
        with open(self.ledger, "w", encoding="utf-8") as handle:
            handle.write(LEDGER)
        with open(self.local, "w", encoding="utf-8") as handle:
            json.dump(LOCAL, handle)

    def by_feature(self, payload):
        return {row["feature"]: row for row in payload["rows"]}

    def test_statuses(self):
        payload = self.grade(self.local, REMOTE)
        rows = self.by_feature(payload)
        self.assertEqual(rows["waitingFeature"]["status"], "WAITING")
        self.assertIsNone(rows["waitingFeature"]["start"])

        running = rows["runningFeature"]
        self.assertEqual(running["status"], "RUNNING")
        self.assertEqual(running["days_left"], 12)
        self.assertEqual(running["own_days"], 2)
        self.assertEqual(running["start"], "2026-10-20")

        keep_own = rows["keepOwn"]
        self.assertEqual(keep_own["status"], "KEEP")
        self.assertEqual(keep_own["own_days"], 3)
        self.assertEqual(keep_own["others_days"], 0)

        keep_others = rows["keepOthers"]
        self.assertEqual(keep_others["status"], "KEEP")
        self.assertEqual(keep_others["own_days"], 0)
        self.assertEqual(keep_others["others_days"], 3)

        review = rows["reviewFeature"]
        self.assertEqual(review["status"], "REVIEW")
        self.assertEqual(review["own_days"], 2)
        self.assertEqual(review["others_days"], 1)
        self.assertEqual(review["used_days"], 2)

        decided = rows["decidedFeature"]
        self.assertEqual(decided["status"], "DECIDED")
        self.assertIn("bleibt", decided["decision"])

        tagged = rows["tagFeature"]
        self.assertEqual(tagged["status"], "KEEP")
        self.assertEqual(tagged["own_days"], 3)
        self.assertEqual(tagged["start"], "2026-08-01")

        order = [row["status"] for row in payload["rows"]]
        self.assertEqual(order, sorted(order, key=lambda status: self.fb.ORDER.index(status)))
        self.assertEqual(order[0], "REVIEW")
        self.assertTrue(payload["summary"].startswith("Ergebnis:"))
        self.assertTrue(any("Schätzung" in note for note in payload["notes"]))

    def test_markdown_order_and_write(self):
        out_dir = os.path.join(self.tmp.name, "out")
        argv = ["--ledger", self.ledger, "--local", self.local, "--today", TODAY,
                "--write", out_dir]
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = self.fb.main(
                argv, git_commit=fake_commit, git_tag=fake_tag, git_date=fake_date,
                bq=(lambda: REMOTE))
        self.assertEqual(code, 0)
        text = buffer.getvalue()
        self.assertTrue(text.startswith("Ergebnis:"))
        statuses = [line.split()[0] for line in text.splitlines() if line.split()[:1] and line.split()[0] in self.fb.ORDER]
        self.assertEqual(statuses[0], "REVIEW")
        self.assertLess(statuses.index("REVIEW"), statuses.index("RUNNING"))
        self.assertLess(statuses.index("RUNNING"), statuses.index("KEEP"))
        self.assertLess(statuses.index("KEEP"), statuses.index("WAITING"))
        self.assertLess(statuses.index("WAITING"), statuses.index("DECIDED"))
        for name in ("LATEST.md", TODAY + ".md"):
            written = (Path(out_dir) / name).read_text(encoding="utf-8")
            self.assertEqual(written, text)

    def test_missing_local_file(self):
        missing = os.path.join(self.tmp.name, "no-such-feature-usage.json")
        payload = self.grade(missing, {}, no_remote=True)
        rows = self.by_feature(payload)
        self.assertEqual(rows["keepOwn"]["status"], "REVIEW")
        self.assertEqual(rows["keepOwn"]["own_days"], 0)
        self.assertEqual(rows["waitingFeature"]["status"], "WAITING")
        self.assertEqual(rows["decidedFeature"]["status"], "DECIDED")
        self.assertEqual(rows["runningFeature"]["status"], "RUNNING")
        joined = "\n".join(payload["notes"])
        self.assertIn("fehlt", joined)
        self.assertIn(missing, joined)

    def test_remote_failure_still_grades_local(self):
        payload = self.grade(self.local, None)
        rows = self.by_feature(payload)
        self.assertEqual(payload["remote"], "unavailable")
        self.assertEqual(rows["keepOwn"]["status"], "KEEP")
        self.assertEqual(rows["keepOthers"]["status"], "REVIEW")
        self.assertTrue(any("nicht erreichbar" in note for note in payload["notes"]))


if __name__ == "__main__":
    unittest.main()
