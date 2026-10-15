#!/usr/bin/env python3
"""Write a single-item Sparkle 2 appcast for one release (stdlib only)."""
import argparse
import html
import re
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.sax.saxutils import quoteattr


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
    a = ap.parse_args()

    try:
        with open(a.notes, encoding="utf-8") as f:
            notes_html = markdown_to_html(f.read())
    except FileNotFoundError:
        notes_html = ""
    notes_html = notes_html.replace("]]>", "]]&gt;")
    pub = format_datetime(datetime.now(timezone.utc), usegmt=True)
    title = html.escape("WhisperShortcut %s" % a.version, quote=False)

    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>WhisperShortcut</title>
    <item>
      <title>{title}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{html.escape(a.build, quote=False)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(a.version, quote=False)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(a.min_system, quote=False)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes_html}]]></description>
      <enclosure url={quoteattr(a.url)} length={quoteattr(a.length)} type="application/octet-stream" sparkle:edSignature={quoteattr(a.signature)}/>
    </item>
  </channel>
</rss>
"""
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(xml)


if __name__ == "__main__":
    main()
