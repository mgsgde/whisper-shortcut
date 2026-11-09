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


def write_appcast(extra, notes="Hello **notes**.", previous=None, notes_de=None):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        notes_path = root / "notes.md"
        notes_path.write_text(notes, encoding="utf-8")
        out = root / "appcast.xml"
        if previous is not None:
            prev = root / "previous.xml"
            prev.write_text(previous, encoding="utf-8")
            extra = extra + ["--previous", str(prev)]
        if notes_de is not None:
            de_path = root / "notes.de.md"
            de_path.write_text(notes_de, encoding="utf-8")
            extra = extra + ["--notes-de", str(de_path)]
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

    def test_notes_de_adds_localized_description(self):
        xml = write_appcast([], notes_de="Hallo **Notizen**.")
        items = ITEM_RE.findall(xml)
        self.assertEqual(len(items), 1)
        descriptions = re.findall(
            r"<description\b([^>]*)><!\[CDATA\[(.*?)\]\]></description>",
            items[0],
            re.DOTALL,
        )
        self.assertEqual(len(descriptions), 2)
        self.assertEqual(descriptions[0][0], ' xml:lang="en"')
        self.assertIn("<p>Hello <strong>notes</strong>.</p>", descriptions[0][1])
        self.assertEqual(descriptions[1][0], ' xml:lang="de"')
        self.assertIn("<p>Hallo <strong>Notizen</strong>.</p>", descriptions[1][1])
        english = items[0].index('<description xml:lang="en">')
        german = items[0].index('<description xml:lang="de">')
        enclosure = items[0].index("<enclosure ")
        self.assertLess(english, german)
        self.assertLess(german, enclosure)

    def test_without_notes_de_exactly_one_description(self):
        xml = write_appcast([])
        items = ITEM_RE.findall(xml)
        self.assertEqual(len(re.findall(r"<description\b", items[0])), 1)
        self.assertNotIn("xml:lang", xml)

        missing = write_appcast(["--notes-de", "/no/such/notes.de.md"])
        missing_items = ITEM_RE.findall(missing)
        self.assertEqual(len(re.findall(r"<description\b", missing_items[0])), 1)
        self.assertNotIn("xml:lang", missing)

        empty = write_appcast([], notes_de="")
        empty_items = ITEM_RE.findall(empty)
        self.assertEqual(len(re.findall(r"<description\b", empty_items[0])), 1)
        self.assertNotIn("xml:lang", empty)

        blank = write_appcast([], notes_de="\n  \n")
        blank_items = ITEM_RE.findall(blank)
        self.assertEqual(len(re.findall(r"<description\b", blank_items[0])), 1)
        self.assertNotIn("xml:lang", blank)

    def test_previous_german_description_kept_verbatim(self):
        german = (
            '<description xml:lang="de"><![CDATA[<p>Alte <strong>Notizen</strong></p>]]></description>'
        )
        old_item = (
            "<item><sparkle:version>1</sparkle:version>"
            "<description><![CDATA[<p>Old</p>]]></description>\n      %s\n</item>" % german
        )
        previous = (
            '<?xml version="1.0" encoding="UTF-8"?>\n<rss><channel>\n%s\n</channel></rss>\n'
            % old_item
        )
        xml = write_appcast(
            ["--build", "9", "--version", "9.0"],
            notes_de="Neu **heute**.",
            previous=previous,
        )
        items = ITEM_RE.findall(xml)
        self.assertEqual(item_versions(xml), ["9", "1"])
        self.assertEqual(items[1], old_item)
        self.assertIn(german, items[1])
        new_descriptions = re.findall(r"<description\b", items[0])
        self.assertEqual(len(new_descriptions), 2)


if __name__ == "__main__":
    unittest.main()
