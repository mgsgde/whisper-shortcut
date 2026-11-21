#!/usr/bin/env python3
"""Tests for scripts/merge-train/runner_outage.py. Stdlib only."""
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runner_outage as ro  # noqa: E402

MARKED = ["The job was not acquired by Runner of type hosted even after multiple attempts",
          "Due to capacity constraints, ..."]
NOTICE = ["Due to capacity constraints, the job waited too long"]


def job(conclusion, ann=None):
    return {"conclusion": conclusion, "annotations": ann or []}


class IsRunnerOutage(unittest.TestCase):
    def test_cancelled_with_marker_plus_success(self):
        self.assertTrue(ro.is_runner_outage([job("cancelled", MARKED), job("success")]))

    def test_cancelled_with_only_notice(self):
        self.assertFalse(ro.is_runner_outage([job("cancelled", NOTICE), job("success")]))

    def test_failure_plus_cancelled(self):
        self.assertFalse(ro.is_runner_outage([job("failure"), job("cancelled", MARKED)]))

    def test_two_cancelled_one_marked(self):
        self.assertFalse(ro.is_runner_outage([job("cancelled", MARKED), job("cancelled", NOTICE)]))

    def test_all_success(self):
        self.assertFalse(ro.is_runner_outage([job("success"), job("success")]))

    def test_empty(self):
        self.assertFalse(ro.is_runner_outage([]))

    def test_skipped_neutral_plus_cancelled(self):
        self.assertTrue(ro.is_runner_outage(
            [job("skipped"), job("neutral"), job("cancelled", MARKED)]))


class Decide(unittest.TestCase):
    def test_table(self):
        self.assertEqual(ro.decide(True, 1, 2), "rerun")
        self.assertEqual(ro.decide(True, 2, 2), "rerun")
        self.assertEqual(ro.decide(True, 3, 2), "red")
        self.assertEqual(ro.decide(False, 1, 2), "red")
        self.assertEqual(ro.decide(True, 1, 0), "red")


class RunIds(unittest.TestCase):
    def test_cancelled_only(self):
        url = "https://github.com/o/r/actions/runs/%d/job/%d"
        entries = [
            {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "CANCELLED",
             "detailsUrl": url % (200, 1)},
            {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "CANCELLED",
             "detailsUrl": url % (200, 2)},
            {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "CANCELLED",
             "detailsUrl": url % (100, 3)},
            {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE",
             "detailsUrl": url % (300, 4)},
            {"__typename": "StatusContext", "state": "FAILURE",
             "targetUrl": "https://github.com/o/r/actions/runs/400"},
        ]
        self.assertEqual(ro.run_ids_from_rollup(entries), [100, 200])


class Cli(unittest.TestCase):
    def run_main(self, fetch_fn):
        buf = io.StringIO()
        code = ro.main(["check", "o/r", "1"], fetch_fn=fetch_fn, out=buf)
        self.assertEqual(code, 0)
        return buf.getvalue().strip()

    def test_attempt_3_is_red(self):
        out = self.run_main(lambda r, i: (3, [job("cancelled", MARKED)]))
        self.assertEqual(out, "red 3")

    def test_attempt_1_reruns(self):
        out = self.run_main(lambda r, i: (1, [job("cancelled", MARKED), job("success")]))
        self.assertEqual(out, "rerun 1")

    def test_fetch_error_is_red_0(self):
        def boom(r, i):
            raise RuntimeError("gh down")
        self.assertEqual(self.run_main(boom), "red 0")


if __name__ == "__main__":
    unittest.main()
