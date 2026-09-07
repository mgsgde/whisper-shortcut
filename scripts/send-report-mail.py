#!/usr/bin/env python3
"""Mail a report file from an unattended job.

Deliberately independent of the MCP mail server and of Claude itself: a cron job that can only
report its result while an interactive session happens to be running is not a cron job. This
talks to IONOS SMTP directly and reuses the credentials the MCP launcher already set up
(~/.cursor/ionos-mail-mcp.sh) — password from the macOS Keychain, never on disk or in argv.

    python3 scripts/send-report-mail.py --subject "..." --body-file report.md \
        --verdict handled --verdict-handler "the implementer queue" --verdict-detail "..." \
        [--attach raw.txt]

Every mail states, in one banner at the top, whether the reader has to act — the five states and
the reasoning behind them are in scripts/operator_mail.py. A sender that passes no `--verdict`
still sends, loudly flagged as unstated: a mail nobody receives is worse than one whose sender
forgot the flag.

    --verdict fyi                 nothing to do, for information
    --verdict handled             --verdict-handler names the job that has it
    --verdict ships-on-silence    --verdict-stop-with gives the exact stop command
    --verdict needs-decision      --verdict-count says how many
    --verdict needs-fix           broken, nothing automatic covers it
    --verdict proposals           derive fyi/handled from --proposals-file (the loop jobs)

Exit codes: 0 sent, 1 could not send (caller should fall back to a local notification —
the Keychain is unreadable while the Mac is locked, which is a normal condition at 09:17).
"""
import argparse, os, smtplib, subprocess, sys
from email.message import EmailMessage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import operator_mail as om

ACCOUNT = os.environ.get("AUDIT_MAIL_FROM", "mail@magnus-goedde.de")
KEYCHAIN_SERVICE = os.environ.get("AUDIT_MAIL_KEYCHAIN_SERVICE", "cursor-ionos-mail")
SMTP_HOST = os.environ.get("AUDIT_MAIL_SMTP_HOST", "smtp.ionos.de")
SMTP_PORT = int(os.environ.get("AUDIT_MAIL_SMTP_PORT", "465"))
MAX_BODY_BYTES = 200_000


def keychain_password():
    """Same lookup the MCP launcher does. Returns None when the item is missing or the login
    keychain is locked — both are recoverable conditions, not crashes."""
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-a", ACCOUNT, "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"keychain lookup failed: {e}", file=sys.stderr)
        return None
    if out.returncode != 0 or not out.stdout.strip():
        print(f"keychain lookup returned nothing (rc={out.returncode}). "
              f"Store it once with: security add-generic-password -a '{ACCOUNT}' "
              f"-s '{KEYCHAIN_SERVICE}' -w", file=sys.stderr)
        return None
    return out.stdout.strip()


def build_verdict(args):
    """One state per mail, picked by the sender. Anything unstated is reported as unstated rather
    than guessed: claiming a handler that is not armed is the one failure mode worse than silence."""
    if args.verdict == "fyi":
        return om.verdict_fyi(args.verdict_detail or "The report is below.")
    if args.verdict == "handled":
        return om.verdict_handled_by(args.verdict_handler or "an automatic job",
                                     args.verdict_detail or "")
    if args.verdict == "ships-on-silence":
        return om.verdict_ships_on_silence(args.verdict_detail or "",
                                           args.verdict_stop_with or "(no stop command given)")
    if args.verdict == "needs-decision":
        return om.verdict_needs_decision(max(1, args.verdict_count), args.verdict_detail or "")
    if args.verdict == "needs-fix":
        return om.verdict_needs_fix(args.verdict_detail or "The report is below.")
    if args.verdict == "proposals":
        # No path means the job could not say where its proposals went, which is not the same as
        # "it proposed nothing" — and a green banner is exactly the wrong way to report not knowing.
        return om.verdict_for_proposals(args.proposals_file) if args.proposals_file \
            else om.verdict_unstated()
    return om.verdict_unstated()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--to", default=os.environ.get("AUDIT_MAIL_TO", "mail@magnus-goedde.de"))
    ap.add_argument("--subject", required=True)
    ap.add_argument("--body-file", required=True)
    ap.add_argument("--attach", action="append", default=[],
                    help="file to attach (repeatable); silently skipped if missing")
    ap.add_argument("--verdict", choices=["fyi", "handled", "ships-on-silence", "needs-decision",
                                          "needs-fix", "proposals"])
    ap.add_argument("--verdict-detail", default="", help="who acts on this next, and when")
    ap.add_argument("--verdict-handler", default="", help="handled: the job that has it")
    ap.add_argument("--verdict-stop-with", default="", help="ships-on-silence: the stop command")
    ap.add_argument("--verdict-count", type=int, default=1, help="needs-decision: how many")
    ap.add_argument("--proposals-file", default="", help="proposals: the loop's sidecar JSON")
    ap.add_argument("--meta", action="append", default=[], metavar="LABEL=VALUE",
                    help="a row in the small table above the report (repeatable)")
    ap.add_argument("--keep-subject", action="store_true",
                    help="the subject already answers the question — do not append the suffix")
    ap.add_argument("--title", default="", help="heading inside the mail (default: the subject)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the subject and text half, write the HTML to --html-out, send nothing")
    ap.add_argument("--html-out", default="", help="also write the rendered HTML here")
    args = ap.parse_args()

    if not os.path.exists(args.body_file):
        sys.exit(f"body file not found: {args.body_file}")
    body = open(args.body_file, "rb").read()
    truncated = len(body) > MAX_BODY_BYTES
    report = body[:MAX_BODY_BYTES].decode("utf-8", "replace")
    if truncated:
        report += f"\n\n[…truncated at {MAX_BODY_BYTES} bytes — full report: {args.body_file}]"

    verdict = build_verdict(args)
    subject = args.subject if args.keep_subject else om.with_verdict_subject(args.subject, verdict)
    report = om.relabel_run_verdict(report)
    meta_rows = [tuple(m.split("=", 1)) for m in args.meta if "=" in m]

    text = "\n".join([om.verdict_text(verdict), ""]
                     + [f"{k}: {v}" for k, v in meta_rows]
                     + ([""] if meta_rows else [])
                     + ["─" * 32, "", report])
    html = om.render_document(args.title or args.subject, verdict, report, meta_rows)

    if args.html_out:
        with open(args.html_out, "w", encoding="utf-8") as handle:
            handle.write(html)
        print(f"HTML written to {args.html_out}")
    if args.dry_run:
        # The text half says nothing about how the mail actually looks, which is where a
        # dark-mode regression would hide — so --html-out is the half worth opening.
        print(f"[dry-run] To: {args.to}\n[dry-run] Subject: {subject}\n\n{text}")
        return 0

    password = keychain_password()
    if password is None:
        return 1

    msg = EmailMessage()
    msg["From"] = ACCOUNT
    msg["To"] = args.to
    msg["Subject"] = subject
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")

    for path in args.attach:
        if not os.path.exists(path):
            continue
        with open(path, "rb") as f:
            msg.add_attachment(f.read(), maintype="text", subtype="plain",
                               filename=os.path.basename(path))

    try:
        with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=60) as s:
            s.login(ACCOUNT, password)
            s.send_message(msg)
    except Exception as e:                                   # noqa: BLE001 — caller falls back
        print(f"SMTP send failed: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    print(f"mail sent to {args.to}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
