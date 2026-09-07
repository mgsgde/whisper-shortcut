#!/usr/bin/env python3
"""One vocabulary for the question every job mail is opened with: **muss ich hier etwas tun?**

Ported from sabaki.dance's `apps/shared/operator-action.ts` and the banner/shell half of
`apps/shared/html.ts` (2026-09-06, ported here 2026-09-07). The problem it fixes is the same one,
and this repo had it worse: every scheduled job mails a markdown digest whose first line is a
`VERDICT:` about the *finding* — "noSpeechDetected is 76% streaming-chunk noise" — and nothing in
the mail says whether the reader has to act on it. The answer existed: proposals from that run had
already been groomed into `plans/implementer-queue.md`, one row released to build on silence with a
deadline two days out, one waiting for a human. None of that was in the mail.

The fix is not better wording per mail — it is the same five words in the same place every time.
A sender picks a **state**, never a sentence:

    verdict_fyi              ✅ Nothing to do — for your information.
    verdict_handled_by       ✅ Nothing to do — handled automatically.
    verdict_ships_on_silence ⏳ Nothing to do unless you disagree.
    verdict_needs_decision   ⚠️ Needs you: N decisions.
    verdict_needs_fix        🚨 Needs you: nothing automatic covers this.

`detail` is the only variable part and answers exactly one follow-up: *who* does the thing, and
*when*. Claiming a handler that does not exist is worse than claiming nothing — every
`verdict_handled_by` must name a job that is actually armed (the hourly
`com.whispershortcut.implementer-tick`, the weekly health report, the release sweep).

Rendering lives here too, so the banner looks identical in every mail and is dark-mode-safe in one
place. `send-report-mail.py` is the only caller that sends; everything else builds a verdict.

Deliberately dependency-free: these mails are sent from launchd jobs on a bare Mac, where the
system python3 has no markdown library and a failed import means a job that reports nothing.
"""
import html as _html
import json
import os
import re

# ---------------------------------------------------------------------------- the vocabulary

_NOTHING_TO_DO = "✅ Nothing to do — for your information."
_HANDLED = "✅ Nothing to do — handled automatically."
_SILENCE_IS_YES = "⏳ Nothing to do unless you disagree."


class OperatorVerdict:
    """needs_you drives nothing on its own; severity drives the colour, the rest is text."""

    def __init__(self, needs_you, severity, subject_suffix, headline, detail):
        self.needs_you = needs_you
        self.severity = severity          # 'ok' | 'attention' | 'alarm'
        self.subject_suffix = subject_suffix
        self.headline = headline
        self.detail = detail


def verdict_fyi(detail):
    """A record of something that happened. Nobody is going to act on it, including you."""
    return OperatorVerdict(False, "ok", "FYI", _NOTHING_TO_DO, detail)


def verdict_handled_by(handler, detail):
    """Someone else already has this — a tick, the queue, a sweep. `handler` names it in the
    operator's words; `detail` says when it runs and what would bring it back to him."""
    return OperatorVerdict(False, "ok", f"{handler} has it", _HANDLED, detail)


def verdict_ships_on_silence(what, stop_with):
    """The veto pattern: it ships unless he stops it. Not a question — a deadline."""
    return OperatorVerdict(False, "attention", "ships unless you stop it", _SILENCE_IS_YES,
                           f"{what} Silence is a yes. To stop it: {stop_with}")


def verdict_needs_decision(count, detail):
    """A judgement no gate can make. `count` is how many, so the subject can say it."""
    plural = "" if count == 1 else "s"
    return OperatorVerdict(True, "attention", f"{count} decision{plural} for you",
                           f"⚠️ Needs you: {count} decision{plural}.", detail)


def verdict_needs_fix(detail):
    """Something is broken and no automation covers it. The loudest state we have."""
    return OperatorVerdict(True, "alarm", "needs you",
                           "🚨 Needs you: nothing automatic covers this.", detail)


def verdict_unstated():
    """The sender did not say. Loud on purpose and never silent: a mail that cannot answer the
    question is the bug this module exists to remove, so it reports itself rather than sending a
    quiet-looking mail whose sender simply forgot the flag."""
    return OperatorVerdict(True, "attention", "verdict missing",
                           "⚠️ This mail did not say whether you have to act.",
                           "Its sender passed no --verdict to scripts/send-report-mail.py, so read "
                           "it yourself and fix the sender: scripts/operator_mail.py lists the "
                           "five states.")


def verdict_text(verdict):
    """Both halves of a mail carry the verdict; the plain-text one is this."""
    return f"{verdict.headline}\n{verdict.detail}"


def with_verdict_subject(subject, verdict):
    """Subjects read better as `<what> — <verdict>` than the other way round: the mail app
    truncates the tail, and the first words have to say which mail it is."""
    return f"{subject} — {verdict.subject_suffix}"


# ------------------------------------------------------------- the loops' shared queue verdict

def queue_sentence(count):
    """What the queue does with a loop's proposals, in the operator's terms. The chain is real and
    unattended: `$IMPLEMENTER_INCOMING_DIR` → the hourly tick → `groom-queue.py` →
    `plans/implementer-queue.md` (BUILD builds straight away, VETO builds on silence, ASK waits for
    him) → `run-implementer.sh`."""
    return (
        f"{count} proposal{'' if count == 1 else 's'} went to the implementer queue. "
        "The hourly tick grooms them into plans/implementer-queue.md and gate-covered ones are "
        "built unattended; a row it releases on silence is announced with its own deadline mail, "
        "and anything it cannot justify reaches you in the weekly \"machine health\" mail, never here."
    )


def count_proposals(path):
    """How many proposals a run actually handed over. Read from the sidecar the loop wrote, or from
    the groomer's archive when an hourly tick already consumed it — a run whose file was groomed
    between the pass and the mail proposed exactly as much as one whose file is still there."""
    if not path:
        return 0
    candidates = [path, os.path.join(os.path.dirname(path), "archive", os.path.basename(path))]
    for candidate in candidates:
        try:
            with open(candidate, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            continue
        if isinstance(data, list):
            return len(data)
        return 1 if isinstance(data, dict) and data else 0
    return 0


def verdict_for_proposals(path):
    """The verdict a finished loop run gets, derived from machine facts rather than from the run's
    own summary of itself — an agent describing its own run is exactly the thing that drifts."""
    count = count_proposals(path)
    if count == 0:
        return verdict_fyi("This run proposed no code change, so nothing was queued and nothing is "
                           "waiting on you. The digest is below.")
    return verdict_handled_by("the implementer queue", queue_sentence(count))


# ------------------------------------------------------------------------------- rendering

_VERDICT_PALETTE = {
    "ok":        {"bg": "#ecfdf5", "accent": "#059669", "heading": "#065f46"},
    "attention": {"bg": "#fffbeb", "accent": "#d97706", "heading": "#92400e"},
    "alarm":     {"bg": "#fef2f2", "accent": "#dc2626", "heading": "#991b1b"},
}


def render_banner(verdict):
    """The banner that opens a job mail. One look, one position, one vocabulary — so the reader
    answers "do I have to act?" by recognising a colour, not by reading three screens of report.

    The dark palette lives in the document stylesheet under the `verdict-*` classes, because a
    `<style>` block is the only place a media query can go and inline styles cannot switch theme.
    """
    palette = _VERDICT_PALETTE.get(verdict.severity, _VERDICT_PALETTE["attention"])
    return (
        f'<div class="verdict-card verdict-{verdict.severity}" style="background-color:{palette["bg"]};'
        f'border-left:4px solid {palette["accent"]};border-radius:8px;padding:16px 18px;margin:0 0 20px 0;">'
        f'<div class="verdict-headline" style="color:{palette["heading"]};font-size:17px;'
        f'font-weight:bold;line-height:1.35;">{_html.escape(verdict.headline)}</div>'
        f'<div class="verdict-detail" style="color:#4b5563;font-size:14px;line-height:1.55;'
        f'margin-top:8px;">{_linkify(_html.escape(verdict.detail))}</div>'
        f"</div>"
    )


_URL_RE = re.compile(r"(?<![\"'=])\bhttps?://[^\s<>\")]+")


def _linkify(escaped):
    """Bare URLs in already-escaped text. Report bodies carry PR links and `gh` URLs that are worth
    a tap on a phone."""
    return _URL_RE.sub(lambda m: f'<a href="{m.group(0)}">{m.group(0)}</a>', escaped)


_INLINE_CODE_RE = re.compile(r"`([^`]+)`")
_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC_RE = re.compile(r"(?<![*\w])\*([^*\n]+)\*(?!\*)")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")


def _inline(text):
    """Markdown's inline subset, on escaped text. Code first: a backticked span is the one place a
    report writes `**` or `_` and means the characters."""
    out = _html.escape(text)
    spans = []

    def stash(markup):
        spans.append(markup)
        return f"\x00{len(spans) - 1}\x00"

    out = _INLINE_CODE_RE.sub(lambda m: stash(f"<code>{m.group(1)}</code>"), out)
    out = _LINK_RE.sub(lambda m: stash(f'<a href="{m.group(2)}">{m.group(1)}</a>'), out)
    out = _BOLD_RE.sub(r"<strong>\1</strong>", out)
    out = _ITALIC_RE.sub(r"<em>\1</em>", out)
    out = _linkify(out)
    return re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], out)


def _render_table(rows):
    head, body = rows[0], rows[2:]          # rows[1] is the |---|---| separator
    cells = lambda row, tag: "".join(f"<{tag}>{_inline(c)}</{tag}>" for c in row)
    body_html = "".join(f"<tr>{cells(r, 'td')}</tr>" for r in body)
    return f"<table><thead><tr>{cells(head, 'th')}</tr></thead><tbody>{body_html}</tbody></table>"


def _split_row(line):
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


def markdown_to_html(markdown):
    """The markdown subset the job reports actually use: headings, tables, lists, fenced code,
    blockquotes, rules, paragraphs. Not a general parser — a general parser is a dependency, and
    these mails are sent by launchd from a Mac whose python3 has none."""
    lines = markdown.replace("\r\n", "\n").split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]

        if line.strip().startswith("```"):
            i += 1
            block = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                block.append(lines[i])
                i += 1
            i += 1
            out.append(f"<pre><code>{_html.escape(chr(10).join(block))}</code></pre>")
            continue

        if re.match(r"^\s*(?:[-*_]\s*){3,}$", line):
            out.append("<hr>")
            i += 1
            continue

        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            level = min(len(heading.group(1)), 3)
            out.append(f"<h{level}>{_inline(heading.group(2).strip())}</h{level}>")
            i += 1
            continue

        # A table needs its |---|---| second line; without it a line of pipes is prose.
        if line.strip().startswith("|") and i + 1 < len(lines) and re.match(
                r"^\s*\|?[\s:|-]+\|[\s:|-]*$", lines[i + 1]):
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(_split_row(lines[i]))
                i += 1
            out.append(_render_table(rows))
            continue

        if re.match(r"^\s*(?:[-*+]|\d+[.)])\s+", line):
            ordered = bool(re.match(r"^\s*\d+[.)]\s+", line))
            items = []
            while i < len(lines) and re.match(r"^\s*(?:[-*+]|\d+[.)])\s+", lines[i]):
                item = re.sub(r"^\s*(?:[-*+]|\d+[.)])\s+", "", lines[i])
                i += 1
                # A wrapped bullet continues on an indented line with no marker of its own.
                while i < len(lines) and lines[i].strip() and lines[i].startswith((" ", "\t")) \
                        and not re.match(r"^\s*(?:[-*+]|\d+[.)])\s+", lines[i]):
                    item += " " + lines[i].strip()
                    i += 1
                items.append(f"<li>{_inline(item)}</li>")
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>{''.join(items)}</{tag}>")
            continue

        if line.strip().startswith(">"):
            quote = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append(f"<blockquote>{_inline(' '.join(quote))}</blockquote>")
            continue

        if not line.strip():
            i += 1
            continue

        paragraph = []
        while i < len(lines) and lines[i].strip() and not re.match(
                r"^\s*(?:#{1,6}\s|[-*+]\s|\d+[.)]\s|>|\||```)", lines[i]):
            paragraph.append(lines[i].strip())
            i += 1
        out.append(f"<p>{_inline(' '.join(paragraph))}</p>")

    return "\n".join(out)


def relabel_run_verdict(body):
    """The digests open with `VERDICT: <one line about the finding>`, and the jobs read that line
    back for the subject and the notification — so it stays on disk. In the mail it now sits under
    the operator banner, where two lines both called "verdict" answer two different questions, and
    the reader has to work out which one is about him. Same sentence, plain label."""
    lines = body.split("\n")
    if not lines or not lines[0].startswith("VERDICT:"):
        return body
    lines[0] = f"**In one line:** {lines[0][len('VERDICT:'):].strip()}"
    return "\n".join(lines)


def render_document(title, verdict, body_markdown, meta_rows=()):
    """The one HTML document every job mail is delivered inside.

    Everything here exists because the mail is read on a phone first: a real `<html><head>` with a
    viewport (without it a phone lays the body out at desktop width and zooms out), and
    `color-scheme: light dark` so a dark-mode client is told this mail carries its own dark palette
    and must not run its own inversion over it — which is what turns a green card's text grey.
    """
    meta_html = ""
    if meta_rows:
        cells = "".join(
            f'<tr><td class="meta-label" style="color:#6b7280;padding:2px 16px 2px 0;'
            f'white-space:nowrap;">{_html.escape(str(k))}</td>'
            f'<td class="meta-value" style="padding:2px 0;"><strong>{_html.escape(str(v))}</strong></td></tr>'
            for k, v in meta_rows)
        meta_html = (
            f'<table style="margin-bottom:8px;font-size:14px;border-collapse:collapse;">{cells}</table>'
            '<hr class="meta-rule" style="border:none;border-top:1px solid #e5e7eb;margin:16px 0 20px;">')

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>{_html.escape(title)}</title>
<style>
  body {{ margin:0; padding:0; width:100% !important; -webkit-text-size-adjust:100%; }}
  a {{ color:#2563eb; }}
  .wrap {{ background-color:#f3f4f6; padding:16px; }}
  .card {{ background-color:#ffffff; border-radius:12px; padding:24px; max-width:720px; margin:0 auto; }}
  .h1 {{ color:#2563eb; margin:0 0 20px 0; font-size:22px; line-height:1.3; font-weight:bold; }}
  .md {{ color:#374151; font-size:14px; line-height:1.55; overflow-wrap:break-word; }}
  .md h1 {{ font-size:20px; margin:24px 0 12px; color:#111827; }}
  .md h2 {{ font-size:17px; margin:20px 0 10px; color:#1f2937; border-bottom:1px solid #e5e7eb; padding-bottom:4px; }}
  .md h3 {{ font-size:15px; margin:16px 0 8px; color:#374151; }}
  .md p {{ margin:8px 0; }}
  .md ul, .md ol {{ margin:8px 0 8px 20px; padding:0; }}
  .md li {{ margin:4px 0; }}
  .md hr {{ border:none; border-top:1px solid #e5e7eb; margin:20px 0; }}
  .md table {{ border-collapse:collapse; width:100%; margin:12px 0; font-size:13px; }}
  .md th, .md td {{ border:1px solid #d1d5db; padding:6px 8px; text-align:left; vertical-align:top; }}
  .md th {{ background:#f3f4f6; font-weight:600; }}
  .md code {{ font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; background:#f3f4f6; padding:1px 4px; border-radius:3px; }}
  .md pre {{ background:#f3f4f6; border:1px solid #e5e7eb; border-radius:6px; padding:12px; overflow-x:auto; font-size:12px; line-height:1.45; }}
  .md pre code {{ background:none; padding:0; }}
  .md a {{ color:#2563eb; overflow-wrap:anywhere; }}
  .md blockquote {{ margin:12px 0; padding-left:12px; border-left:3px solid #d1d5db; color:#6b7280; }}
  @media only screen and (max-width:480px) {{
    .wrap {{ padding:8px !important; }}
    .card {{ padding:18px 16px !important; border-radius:10px !important; }}
  }}
  @media (prefers-color-scheme: dark) {{
    body, .wrap {{ background-color:#0b0f19 !important; }}
    .card {{ background-color:#161b26 !important; }}
    .h1 {{ color:#93c5fd !important; }}
    .meta-label {{ color:#9ca3af !important; }}
    .meta-value, .meta-value strong {{ color:#e5e7eb !important; }}
    .meta-rule {{ border-top-color:#374151 !important; }}
    .md {{ color:#e5e7eb !important; }}
    .md h1, .md h2, .md h3 {{ color:#f9fafb !important; }}
    .md h2 {{ border-bottom-color:#374151 !important; }}
    .md hr {{ border-top-color:#374151 !important; }}
    .md th, .md td {{ color:#e5e7eb !important; border-color:#374151 !important; }}
    .md th {{ background:#26303f !important; }}
    .md code {{ background:#26303f !important; color:#e5e7eb !important; }}
    .md pre {{ background:#26303f !important; border-color:#374151 !important; color:#e5e7eb !important; }}
    .md a {{ color:#93c5fd !important; }}
    .md blockquote {{ border-left-color:#4b5563 !important; color:#9ca3af !important; }}
    /* The verdict banner's light palette is inline on the element, so the dark one has to be
       spelled out or the mail's most important line is the one that goes unreadable. */
    .verdict-detail, .verdict-detail a {{ color:#d1d5db !important; }}
    .verdict-ok {{ background-color:#12251f !important; border-left-color:#34d399 !important; }}
    .verdict-ok .verdict-headline {{ color:#6ee7b7 !important; }}
    .verdict-attention {{ background-color:#2a2313 !important; border-left-color:#f59e0b !important; }}
    .verdict-attention .verdict-headline {{ color:#fcd34d !important; }}
    .verdict-alarm {{ background-color:#2a1717 !important; border-left-color:#ef4444 !important; }}
    .verdict-alarm .verdict-headline {{ color:#fca5a5 !important; }}
    .foot, .foot a {{ color:#9ca3af !important; }}
    a {{ color:#93c5fd !important; }}
  }}
</style>
</head>
<body style="margin:0;padding:0;background-color:#f3f4f6;">
  <div class="wrap" style="background-color:#f3f4f6;padding:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
    <div class="card" style="background-color:#ffffff;border-radius:12px;padding:24px;max-width:720px;margin:0 auto;">
      <h1 class="h1" style="color:#2563eb;margin:0 0 20px 0;font-size:22px;line-height:1.3;">{_html.escape(title)}</h1>
      {render_banner(verdict)}
      {meta_html}
      <div class="md">
{markdown_to_html(body_markdown)}
      </div>
      <div style="margin-top:28px;padding-top:16px;border-top:1px solid #e5e7eb;">
        <p class="foot" style="color:#9ca3af;margin:0;font-size:12px;">
          Automatic report from a WhisperShortcut scheduled job. Verdict vocabulary:
          scripts/operator_mail.py
        </p>
      </div>
    </div>
  </div>
</body>
</html>"""
