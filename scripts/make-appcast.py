#!/usr/bin/env python3
"""Write a Sparkle 2 appcast for one release and append older items (stdlib only).

The feed is one multi-item appcast. Pass ``--channel latest`` so the new item is
visible only to clients that allow that channel. Untagged items are visible to
everyone (Stable). ``--previous`` is an existing appcast; its ``<item>`` blocks are
kept in order, up to 60 items total. A previous item with the same build is
replaced. If that previous item had no ``<sparkle:channel>`` (it was already
promoted), the new item is written without one too, so re-driving a release
cannot demote it back onto Latest.
"""
import argparse
import html
import re
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.sax.saxutils import quoteattr

MAX_ITEMS = 60
ITEM_RE = re.compile(r"<item\b[^>]*>.*?</item>", re.DOTALL)
VERSION_RE = re.compile(r"<sparkle:version>([^<]*)</sparkle:version>")
CHANNEL_RE = re.compile(r"<sparkle:channel\b")


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(
        r"\[([^\]]+)\]\(([^)\s]+)\)",
        lambda m: '<a href="%s">%s</a>' % (m.group(2).replace('"', "%22"), m.group(1)),
        text,
    )
    return text


def markdown_to_html(md):
    out, para, in_list = [], [], False

    def flush_para():
        if para:
            out.append("<p>%s</p>" % inline(" ".join(para)))
            para.clear()

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in md.splitlines():
        line = raw.rstrip()
        heading = re.match(r"^(#{1,3})\s+(.*)$", line)
        bullet = re.match(r"^\s*[-*]\s+(.*)$", line)
        if not line.strip():
            flush_para()
            close_list()
        elif heading:
            flush_para()
            close_list()
            n = len(heading.group(1))
            out.append("<h%d>%s</h%d>" % (n, inline(heading.group(2)), n))
        elif bullet:
            flush_para()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>%s</li>" % inline(bullet.group(1)))
        else:
            close_list()
            para.append(line.strip())
    flush_para()
    close_list()
    return "\n".join(out)


def previous_items(path):
    """Item blocks from an existing appcast. Missing, unreadable, or empty → none."""
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeError):
        return []
    if not text.strip():
        return []
    return ITEM_RE.findall(text)


def item_build(item):
    match = VERSION_RE.search(item)
    return match.group(1).strip() if match else None


def render_item(version, build, url, length, signature, notes_html, min_system, pub, channel):
    lines = [
        "    <item>",
        "      <title>%s</title>" % html.escape("WhisperShortcut %s" % version, quote=False),
        "      <pubDate>%s</pubDate>" % pub,
        "      <sparkle:version>%s</sparkle:version>" % html.escape(build, quote=False),
        "      <sparkle:shortVersionString>%s</sparkle:shortVersionString>"
        % html.escape(version, quote=False),
    ]
    if channel:
        lines.append(
            "      <sparkle:channel>%s</sparkle:channel>" % html.escape(channel, quote=False)
        )
    lines.extend(
        [
            "      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>"
            % html.escape(min_system, quote=False),
            "      <description><![CDATA[%s]]></description>" % notes_html,
            "      <enclosure url=%s length=%s type=\"application/octet-stream\" sparkle:edSignature=%s/>"
            % (quoteattr(url), quoteattr(length), quoteattr(signature)),
            "    </item>",
        ]
    )
    return "\n".join(lines)


def build_appcast(version, build, url, length, signature, notes_html, min_system, pub, channel, previous_path):
    build = build.strip()
    channel = (channel or "").strip() or None
    kept = []
    for item in previous_items(previous_path):
        if item_build(item) == build:
            # Already promoted: re-driving this build must not put the tag back.
            if not CHANNEL_RE.search(item):
                channel = None
            continue
        kept.append(item)
    items = [
        render_item(version, build, url, length, signature, notes_html, min_system, pub, channel)
    ] + kept
    items = items[:MAX_ITEMS]
    body = "\n".join(items)
    return """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>WhisperShortcut</title>
%s
  </channel>
</rss>
""" % body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--length", required=True)
    ap.add_argument("--signature", required=True)
    ap.add_argument("--notes", required=True)
    ap.add_argument("--min-system", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument(
        "--previous",
        default=None,
        help="Existing appcast.xml. Missing, unreadable, or empty is ignored.",
    )
    ap.add_argument(
        "--channel",
        default=None,
        help="When set, the new item carries <sparkle:channel>NAME</sparkle:channel>.",
    )
    a = ap.parse_args()

    try:
        with open(a.notes, encoding="utf-8") as f:
            notes_html = markdown_to_html(f.read())
    except FileNotFoundError:
        notes_html = ""
    notes_html = notes_html.replace("]]>", "]]&gt;")
    pub = format_datetime(datetime.now(timezone.utc), usegmt=True)
    xml = build_appcast(
        a.version,
        a.build,
        a.url,
        a.length,
        a.signature,
        notes_html,
        a.min_system,
        pub,
        a.channel,
        a.previous,
    )
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(xml)


if __name__ == "__main__":
    main()
