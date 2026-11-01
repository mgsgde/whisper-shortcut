#!/usr/bin/env python3
"""Tests for scripts/make-appcast.py. Stdlib only."""
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "make-appcast.py"
ITEM_RE = re.compile(r"<item\b[^>]*>.*?</item>", re.DOTALL)
VERSION_RE = re.compile(r"<sparkle:version>([^<]*)</sparkle:version>")


def write_appcast(extra, notes="Hello **notes**.", previous=None):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        notes_path = root / "notes.md"
        notes_path.write_text(notes, encoding="utf-8")
        out = root / "appcast.xml"
        if previous is not None:
            prev = root / "previous.xml"
            prev.write_text(previous, encoding="utf-8")
            extra = extra + ["--previous", str(prev)]
        cmd = [
            sys.executable,
            str(SCRIPT),
            "--version",
            "1.2.3",
            "--build",
            "100",
            "--url",
            "https://example.com/WhisperShortcut.dmg",
            "--length",
            "10",
            "--signature",
            "abc",
            "--notes",
            str(notes_path),
            "--min-system",
            "15.5",
            "--out",
            str(out),
        ] + extra
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise AssertionError("make-appcast.py failed:\n%s\n%s" % (proc.stdout, proc.stderr))
        return out.read_text(encoding="utf-8")


def item_versions(xml):
    return [VERSION_RE.search(item).group(1) for item in ITEM_RE.findall(xml)]


class MakeAppcastTests(unittest.TestCase):
    def test_no_previous_is_a_single_item(self):
        xml = write_appcast([])
        self.assertEqual(item_versions(xml), ["100"])
        self.assertEqual(len(ITEM_RE.findall(xml)), 1)
        self.assertNotIn("<sparkle:channel>", xml)

        missing = write_appcast(["--previous", "/no/such/appcast.xml"])
        self.assertEqual(item_versions(missing), ["100"])

        empty = write_appcast([], previous="")
        self.assertEqual(item_versions(empty), ["100"])

    def test_channel_tag_present(self):
        xml = write_appcast(["--channel", "latest"])
        self.assertIn("<sparkle:channel>latest</sparkle:channel>", xml)
        self.assertEqual(item_versions(xml), ["100"])

    def test_previous_items_kept_in_order(self):
        previous = """<?xml version="1.0" encoding="UTF-8"?>
<rss><channel>
<item><sparkle:version>1</sparkle:version><sparkle:shortVersionString>0.1</sparkle:shortVersionString><sparkle:channel>latest</sparkle:channel><note>KEEP-A</note></item>
<item><sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.2</sparkle:shortVersionString><note>KEEP-B</note></item>
</channel></rss>
"""
        xml = write_appcast(["--channel", "latest", "--build", "9", "--version", "9.0"], previous=previous)
        self.assertEqual(item_versions(xml), ["9", "1", "2"])
        items = ITEM_RE.findall(xml)
        self.assertIn("KEEP-A", items[1])
        self.assertIn("<sparkle:channel>latest</sparkle:channel>", items[1])
        self.assertIn("KEEP-B", items[2])
        self.assertNotIn("KEEP-B", items[1])

    def test_same_build_replacement_keeps_untagged_state(self):
        previous = """<?xml version="1.0"?>
<rss><channel>
<item><sparkle:version>100</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><note>OLD-PROMOTED</note></item>
<item><sparkle:version>50</sparkle:version><sparkle:shortVersionString>0.9</sparkle:shortVersionString><note>KEEP-AFTER</note></item>
</channel></rss>
"""
        xml = write_appcast(["--channel", "latest"], notes="NEW-NOTES", previous=previous)
        items = ITEM_RE.findall(xml)
        self.assertEqual(item_versions(xml), ["100", "50"])
        self.assertNotIn("<sparkle:channel>", items[0])
        self.assertNotIn("OLD-PROMOTED", xml)
        self.assertIn("NEW-NOTES", items[0])
        self.assertIn("KEEP-AFTER", items[1])

    def test_same_build_replacement_of_tagged_item_keeps_channel(self):
        previous = """<rss><channel>
<item><sparkle:version>100</sparkle:version><sparkle:channel>latest</sparkle:channel><note>OLD-LATEST</note></item>
</channel></rss>
"""
        xml = write_appcast(["--channel", "latest"], notes="REDROVE", previous=previous)
        items = ITEM_RE.findall(xml)
        self.assertEqual(len(items), 1)
        self.assertIn("<sparkle:channel>latest</sparkle:channel>", items[0])
        self.assertNotIn("OLD-LATEST", xml)
        self.assertIn("REDROVE", items[0])

    def test_sixty_item_cap(self):
        blocks = []
        for n in range(1, 71):
            blocks.append(
                "<item><sparkle:version>%d</sparkle:version><sparkle:shortVersionString>0.%d</sparkle:shortVersionString></item>"
                % (n, n)
            )
        previous = "<rss><channel>%s</channel></rss>" % "".join(blocks)
        xml = write_appcast(
            ["--channel", "latest", "--build", "1000", "--version", "1000.0"],
            previous=previous,
        )
        versions = item_versions(xml)
        self.assertEqual(len(versions), 60)
        self.assertEqual(versions[0], "1000")
        self.assertEqual(versions[1:], [str(n) for n in range(1, 60)])
        self.assertNotIn("<sparkle:version>60</sparkle:version>", xml)
        self.assertNotIn("<sparkle:version>70</sparkle:version>", xml)


if __name__ == "__main__":
    unittest.main()
