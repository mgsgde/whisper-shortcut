# Use your ChatGPT plan (Sign in with ChatGPT, open-source flow)

**Status:** Planned, not started. Direct-download (GitHub) build only.
**Audience:** LLM implementing it end-to-end, one slice per PR. UI (settings card, first-sign-in
notice, model picker entry) is written by the Opus session; OAuth client, token store, Responses
request builder and tests go to the cheap hand.
**Origin:** Magnus, 2026-10-21: let people use their ChatGPT subscription instead of an API key.
**Source of truth:** https://developers.openai.com/siwc/llms-full.txt (fetched 2026-10-21). Re-read
"Preview limitations" and "Registration and sign-in" before each slice; the flow is a preview.

---

## What OpenAI offers, and what it does not

- ChatGPT Plus and Pro users can authorize an app to spend their plan on **Responses API**
  requests (`POST https://api.openai.com/v1/responses`). No API key, no client secret.
- Self-serve for open-source, locally hosted apps: the app registers itself on first sign-in
  (`client_id=dynamic_agent_client`). Paid or remotely hosted apps must go through OpenAI's interest
  form instead — so the **App Store build does not get this** until OpenAI approves it
  (`#if !APP_STORE`).
- **Not supported:** audio/video input and the transcription API. Dictation itself cannot run on
  the ChatGPT plan. Transcription stays on Parakeet/Whisper on-device or the user's Gemini/OpenAI key.
- Plus users share one five-hour limit across every app that uses their plan; users set a weekly
  per-app cap in ChatGPT settings. Limit errors arrive mid-stream and must be shown, not retried.

## What the user sees

Settings → Accounts, new card above the API keys:

```
┌──────────────────────────────────────────────────────────────────┐
│ Use your ChatGPT plan                                            │
│ Chat and Dictate Prompt run on your ChatGPT Plus or Pro plan.    │
│ Dictation still needs an on-device model or an API key.          │
│                                     [ (ChatGPT) Continue with ChatGPT ] │
└──────────────────────────────────────────────────────────────────┘
→ connected:  ✓ Signed in as name@example.com · Plus      [Sign out]
              Manage usage limits in ChatGPT settings ↗
```

- Button label exactly **Continue with ChatGPT**, OpenAI branding (UI/UX guidelines page).
- One-time notice after the first successful sign-in: "You're using your ChatGPT plan" + Got it.
  Never shown again.
- Model picker: a "ChatGPT plan" group listing the models the signed-in account can use; it only
  appears while signed in. The Welcome Tour's provider step gets "Continue with ChatGPT" as a third
  path next to "Enter an API key" and "Offline".

## Flow (per the docs)

1. Generate once and persist `ext_agent_host_id` = `urn:uuid:<UUIDv4>` (UserDefaults, not
   user-identifying).
2. Start `LoopbackOAuthListener` — it already binds `127.0.0.1` on a free port. The docs require the
   path `/auth/callback` on `127.0.0.1` (never `localhost`); only the port may change between
   sign-ins. Check `LoopbackOAuthListener.callbackPath` matches or make it configurable.
3. Open the authorize URL in the system browser with PKCE S256, fresh `state` + `nonce`
   (`OAuthCSRF`), scopes `openid profile email offline_access resource.invoke
   chatgpt.tokens.use.direct` (verify against the docs), `client_id=dynamic_agent_client`, `agent_name_hint=WhisperShortcut`,
   `ext_agent_host_id`. Reauthorization: saved issued `client_id`, `id_token_hint`, no
   `agent_name_hint`.
4. Callback: validate `state`; on `error=access_denied` stop and keep the card in "not connected".
   Save the issued `client_id`; exchange code + verifier at the token endpoint.
5. Validate the ID token (JWKS signature, issuer, audience = issued client_id, exp, nonce). Check
   granted scopes; without the plan scope show "ChatGPT plan use was not allowed" + retry button.
6. Store client_id, tokens, ID token, scopes, expiry in **one Keychain item** (new
   `KeychainCredential.chatGPTPlan`, JSON). Never in logs, `DebugLogger`, session JSON or usage log.
   Refresh tokens rotate: replace access + refresh + expiry together.
7. Sign out: stop requests, end the renewable session (docs: Accounts and sessions), clear tokens,
   keep client_id + host id for the next sign-in.

## Request contract (differs from the current OpenAI route)

`OpenAIChatProvider` today uses Chat Completions, and Responses only for web search. The plan
route needs a separate Responses builder:

- `store: false`, `stream: true`, full history in `input` (no `previous_response_id`).
- System prompt via `instructions`, never a `role: system` item.
- Omit `temperature`, `top_p`, `max_output_tokens`, `metadata`, `user`, `truncation`, … (full
  list in "Preview limitations"). Thinking effort stays.
- Tools: our function tools (Google, Trello, mail, folder) grouped in a namespace; no hosted tools
  besides web search, which depends on account policy — treat its failure as "search unavailable".
- Images and files allowed; audio parts must never be sent on this route.
- Model list: `GET /v1/models` with the plan token, keep entries with `visibility: "list"`. A
  listed model is a catalog entry, not an entitlement; only a completed request proves access.
- Success only on `response.completed`. Map `subscription_sharing_usage_limit_exceeded`,
  `subscription_sharing_usage_unavailable`, `subscription_sharing_user_not_eligible` to clear
  messages ("Your ChatGPT plan limit is reached — resets …", "Your plan or workspace does not allow
  this") and do not loop through OAuth.

## Which features use it

| Feature | On the ChatGPT plan? |
|---|---|
| Chat | Yes |
| Dictate Prompt | Yes, as a two-step run: transcribe with the dictation model, then send text. Today the OpenAI path sends the recording as `input_audio` (`SpeechService.swift` ~1344–1416); that is not allowed on this route |
| Read Aloud Smart Rewrite | Yes |
| Smart Improvement, Writing Style profile | Yes |
| Dictation, Live Meeting transcription | No (audio) |
| Read Aloud synthesis | No (TTS is not Responses) |

## Slices

1. **OAuth client + token store** — host id, authorize URL builder, callback handling, token
   exchange, ID-token validation, refresh, sign out. Unit tests on URL building, state/nonce
   checks, scope parsing and refresh replacement. No UI.
2. **Responses route** — `ChatGPTPlanChatProvider` (or a route on `OpenAIChatProvider`) with the
   contract above and the error mapping. Tests on the request body (no forbidden fields) and the
   SSE terminal-event handling.
3. **UI** (Opus) — Settings card, first-sign-in notice, model picker group, Welcome Tour path.
   Verified in the running Dev build with screenshots.
4. **Dictate Prompt two-step** — text route when the prompt model is the ChatGPT plan.
5. README `## Features` entry + website copy.

## Open questions

- Exact authorize/token endpoint URLs and scope strings: copy from "Registration and sign-in",
  don't guess.
- App Store build: depends on OpenAI's answer to the interest form (filled 2026-10-21). Until
  then the feature compiles out of the App Store build — shipping it there would be "offering it to
  users" in a paid app before approval.
- Which plans: the developer docs say Plus and Pro; OpenAI's help article (updated 2026-10-20) says
  Go, Plus and Pro for commercial apps and "all ChatGPT users" for supported open-source tools.
  Check with a real Go/Free account before writing the card copy; let `subscription_sharing_user_not_eligible`
  decide at runtime rather than gating by plan name in the app.
- "Open-source partner" has no definition in the docs. The GitHub build (AGPL-3.0, free, runs
  locally) fits the cookbook's "open-source tools and personal projects that run locally".
