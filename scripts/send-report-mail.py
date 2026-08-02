#!/usr/bin/env python3
"""Mail a report file from an unattended job.

Deliberately independent of the MCP mail server and of Claude itself: a cron job that can only
report its result while an interactive session happens to be running is not a cron job. This
talks to IONOS SMTP directly and reuses the credentials the MCP launcher already set up
(~/.cursor/ionos-mail-mcp.sh) — password from the macOS Keychain, never on disk or in argv.

    python3 scripts/send-report-mail.py --subject "..." --body-file report.md [--attach raw.txt]

Exit codes: 0 sent, 1 could not send (caller should fall back to a local notification —
the Keychain is unreadable while the Mac is locked, which is a normal condition at 09:17).
"""
import argparse, os, smtplib, subprocess, sys
from email.message import EmailMessage

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--to", default=os.environ.get("AUDIT_MAIL_TO", "mail@magnus-goedde.de"))
    ap.add_argument("--subject", required=True)
    ap.add_argument("--body-file", required=True)
    ap.add_argument("--attach", action="append", default=[],
                    help="file to attach (repeatable); silently skipped if missing")
    args = ap.parse_args()

    if not os.path.exists(args.body_file):
        sys.exit(f"body file not found: {args.body_file}")
    body = open(args.body_file, "rb").read()
    truncated = len(body) > MAX_BODY_BYTES
    text = body[:MAX_BODY_BYTES].decode("utf-8", "replace")
    if truncated:
        text += f"\n\n[…truncated at {MAX_BODY_BYTES} bytes — full report: {args.body_file}]"

    password = keychain_password()
    if password is None:
        return 1

    msg = EmailMessage()
    msg["From"] = ACCOUNT
    msg["To"] = args.to
    msg["Subject"] = args.subject
    msg.set_content(text)

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
