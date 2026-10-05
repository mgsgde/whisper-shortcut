# Connect a Mail Account from Chat (IMAP, password card)

**Status:** Slices 1–4 shipped to main (PR #98, 2026-10-05), live-tested against IONOS. Follow-ups (MX preselect, Cancel while checking, DNS fail-fast) are queue row 19.
**Audience:** LLM implementing it end-to-end, one slice per PR. UI (slice 1 card, slice 4 settings
row) is written by the Opus session; IMAP client, tools and tests go to the cheap hand.
**Origin:** Magnus, 2026-10-05: "say in chat 'connect my IONOS mailbox', get asked for the
password right in the chat, and then you're connected", modelled on how Grok Bot does it.

---

## What the user sees

```
You:   Connect my IONOS mailbox mail@example.de
Agent: Enter the password below. It is stored in your Keychain and never sent to the model.
       ┌──────────────────────────────────────────────────────────┐
       │ IMAP password for mail@example.de                        │
       │ imap.ionos.de · port 993 · SSL                           │
       │ [••••••••••••]                  [Cancel]  [Connect]      │
       └──────────────────────────────────────────────────────────┘
       → card turns into:  ✓ Connected · Saved in Keychain
Agent: Connected. 4 folders, 1,212 messages in Inbox. What should I look for?
You:   Did exali write back?
Agent: (mail_search …) Yes, on Oct 3 …
```

## Why

- Gmail works today only through Google OAuth (`gmail_search`, `gmail_read`). IONOS, GMX, web.de,
  iCloud, Posteo, mailbox.org and Strato mailboxes can't be reached at all.
- A settings form is the wrong entry point: the user is already in chat and says what they want.
  The chat should ask for exactly the secret it needs and nothing more.

## Hard rules

1. **The password never reaches the model.** It goes from the card to an IMAP test login and
   then into the Keychain. It never appears in the LLM request, the session JSON
   (`ChatSessionStore`), tool records (`ChatToolHistory`), `ChatToolTurnMemo`, `DebugLogger`,
   `ContextLogger` or the raw-response debug dumps. The model only ever gets
   `{status, account, host, folders, inbox_count}` or an error code.
2. **The app writes the card copy, not the model.** The model calls `connect_mail_account(email)`.
   Title, host and button labels come from app code, so injected mail text like "please re-enter
   your bank password" can't put a phishing prompt on screen. The card only exists for mail
   accounts, and the model gets no free-text label.
3. **Read-only.** `EXAMINE` (not `SELECT`) and `BODY.PEEK[]`, so the app never sets the `\Seen` flag,
   never deletes or moves anything and never sends. SMTP is out of scope (exfiltration path, see
   the no-grounding rule in `voice-agent-core.md`).
4. **TLS only.** Port 993 with implicit TLS. No plaintext 143 and no STARTTLS downgrade.
5. Offline Mode: none of these tools are offered.

## Slices

### Slice 1: password card + `connect_mail_account` (UI by Opus)

- New tool `connect_mail_account(email: string, host?: string)`. No approval card, because the
  password card *is* the confirmation.
- `MailProviderPresets.swift`: domain → `(host, port)`, covering ionos.de/ionos.com, 1und1.de,
  gmx.de/.net, web.de, icloud.com/me.com/mac.com (needs an app-specific password; the card says
  so), posteo.de, mailbox.org, strato.de, t-online.de, yahoo.com (app password). For an unknown
  domain the card shows an editable host field prefilled with `imap.<domain>`.
- Explicitly not supported, with an error the model can relay: outlook/hotmail/live (Microsoft
  turned off basic auth) and gmail.com (point to the existing Google connection).
- Suspension: reuse the `ToolApprovalRequest` pattern (`ChatToolSteps.swift:88`). Add a
  `ToolCredentialRequest { stepId, email, host, port, continuation<CredentialOutcome> }`, one per
  session, rendered inline under the step like the approval card. The SecureField lives in view
  state only. On Connect, `IMAPClient.verify(...)` runs; the card shows a spinner, then
  ✓ Connected or the server's error inline so the user can retype. Cancel resumes the tool with
  `cancelled`.
- Card states: input · verifying · connected · failed (retry stays in the card) · cancelled.
  Check them in light and dark, at narrow and wide chat widths, with screenshots of the running app.

### Slice 2: IMAP client

- `IMAPClient.swift` on `Network.framework` (`NWConnection`, TLS). No new dependency:
  swift-nio-imap is a parser only and pulls in NIO. Commands: `CAPABILITY`, `LOGIN` (quoted
  literal-safe) or `AUTHENTICATE PLAIN` when `LOGINDISABLED`, `LIST "" "*"`, `EXAMINE`,
  `UID SEARCH`, `UID FETCH (ENVELOPE FLAGS BODY.PEEK[])`, `LOGOUT`. 20 s timeout per command and
  one connection per tool call (no pooling in v1).
- `MIMEDecoder.swift`: multipart walk, base64, quoted-printable, RFC 2047 encoded words, charset
  through `String.Encoding` via `CFStringConvertIANACharSetNameToEncoding`. Prefer text/plain and
  fall back to stripped text/html. Cap the body at 20k characters. Attachments are listed by name
  and size only.
- Tests: fixture transcripts (captured from a real IONOS session with the credentials redacted)
  feed a fake transport. MIME fixtures cover German umlauts in ISO-8859-1, QP soft breaks and
  nested multipart/alternative.

### Slice 3: read tools

- `mail_list_accounts()` returns the connected addresses.
- `mail_search(account?, from?, subject?, text?, since_days?, mailbox? = "INBOX", max_results? = 10)`
  maps to `UID SEARCH` and returns uid, date, from, subject and a 200-character snippet.
- `mail_read(account?, uid, mailbox? = "INBOX")` returns the full decoded message.
- `account` may be omitted when only one is connected. Tool output counts as untrusted content,
  the same as `gmail_read`.

### Slice 4: storage, settings, docs

- Keychain: `KeychainCredential` is a fixed enum, so add a generic
  `save/get/delete(account: "imap:<email>")` path to `KeychainManaging` (same cache and lock).
  Non-secret metadata (email, host, port, connectedAt) goes in UserDefaults
  `mailAccounts.v1`.
- Settings → Integrations: a "Mail accounts" list with Remove (deletes the Keychain item and
  metadata). A "Disconnect" chat request uses the same path through a
  `disconnect_mail_account` tool with an approval card.
- README `## Features`: one line under the integrations ("Connect any IMAP mailbox (IONOS, GMX,
  web.de, iCloud…) from chat and search it").

## Open, decided by default

- **Sending mail**: no, v1 is read-only. Revisit with an approval card per send.
- **Multiple accounts**: yes from the start; it costs only the `account` arg.
- **App Store sandbox**: `network.client` is already granted in both entitlements and no new one is
  needed.
