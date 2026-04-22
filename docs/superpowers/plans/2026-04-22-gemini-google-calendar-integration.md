# Gemini Chat + Google Calendar Implementation Plan

> **For agentic workers:** Use **subagent-driven-development** or **executing-plans** to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users connect their Google account once via OAuth; Gemini Chat gains function-calling tools that list and create calendar events (and optionally Google Tasks later) by calling Google APIs from the app, not via `gcloud` or external CLIs.

**Architecture:** Developer registers one OAuth **Desktop** client in Google Cloud (APIs enabled, consent screen). The app stores **refresh + access tokens** in **Keychain**, refreshes access tokens as needed, and implements a small **Calendar API** client (`URLSession`). `GeminiChatToolRegistry` gains new **function declarations** + `execute` branches that call the client; `GeminiChatView` only registers those tools when the user is connected (or returns a clear `not_connected` payload—pick one approach and keep it consistent).

**Tech Stack:** Swift 5.9+, macOS 15.5+, `AuthenticationServices` (`ASWebAuthenticationSession`), `URLSession`, Keychain (extend `KeychainManager`), existing `GeminiChatView` tool loop and `GeminiChatToolRegistry`.

**Constraints:** User-facing strings in **English** (project rule). Use `DebugLogger` only; never log refresh tokens or access tokens. Project convention: agent does **not** run XCTest from automation—verify with **Debug build in Xcode** and manual chat scenarios.

**Prerequisite (developer-only, not end users):** Google Cloud project with **Google Calendar API** enabled, **OAuth consent screen** configured, **OAuth 2.0 Client ID** type **Desktop app** (or macOS where offered), authorized redirect URI matching the app’s custom URL scheme flow (e.g. `com.googleusercontent.apps.<CLIENT_ID>:/oauthredirect` for Google’s iOS/mac pattern, or `http://127.0.0.1:<port>` for loopback—choose one documented flow and stick to it). Note: **Google Tasks API** is a separate optional phase (YAGNI unless explicitly required).

---

## File map (planned)

| File | Responsibility |
|------|----------------|
| `WhisperShortcut/GoogleCalendarOAuthConfig.swift` (new) | Non-secret config: client ID pieces, redirect URI string, scope constants. **Do not** embed client secret for Desktop public client (none required). |
| `WhisperShortcut/GoogleCalendarOAuthService.swift` (new) | PKCE generation, `ASWebAuthenticationSession`, code exchange, token refresh; calls Keychain for persistence. |
| `WhisperShortcut/GoogleCalendarAPIClient.swift` (new) | Minimal REST: `events.list`, `events.insert` (primary calendar or selected calendar ID). |
| `WhisperShortcut/KeychainManager.swift` | Add accounts for refresh token (and optional access token + expiry if stored). |
| `WhisperShortcut/GeminiChatTools.swift` | New tool declarations + `execute` cases; delegate to API client; guard when disconnected. |
| `WhisperShortcut/GeminiChatView.swift` | Build tool list: base tools + calendar tools only if connected; pass through to provider. |
| `WhisperShortcut/Settings/Tabs/OpenGeminiSettingsTab.swift` (or new section file) | "Connect Google Calendar" / "Disconnect", status label. |
| `WhisperShortcut/Info.plist` | `CFBundleURLTypes` for OAuth redirect scheme (if using custom URL scheme). |
| `WhisperShortcut/FullApp.swift` (or app delegate entry) | Handle `onOpenURL` / `NSAppleEventManager` if needed to complete OAuth redirect for SwiftUI lifecycle. |
| `WhisperShortcut/WhisperShortcut.entitlements` | Revisit if **App Sandbox** is re-enabled: outgoing network is already `network.client`; OAuth may need nothing extra for HTTPS. |

---

### Task 1: Google Cloud + OAuth wiring (config only in repo)

**Files:**

- Create: `WhisperShortcut/GoogleCalendarOAuthConfig.swift`
- Modify: `WhisperShortcut/Info.plist`
- Modify: `WhisperShortcut/FullApp.swift` (or equivalent app entry that handles URLs)

- [ ] **Step 1: Add OAuth config type**

Create `GoogleCalendarOAuthConfig.swift` with static strings loaded from **Info.plist custom keys** (recommended) or build settings so CI does not require secrets in source:

- Keys such as `GoogleOAuthClientID`, `GoogleCalendarRedirectURI` (values supplied per build / local plist override).
- Scopes (initial YAGNI set): `https://www.googleapis.com/auth/calendar.events` (create/read own events) **or** narrower `calendar.events.readonly` first if you only want listing—**decide in implementation**: recommend **events** scope so create works.

```swift
import Foundation

enum GoogleCalendarOAuthConfig {
  static var clientID: String {
    (Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String) ?? ""
  }
  static var redirectURI: String {
    (Bundle.main.object(forInfoDictionaryKey: "GoogleCalendarRedirectURI") as? String) ?? ""
  }
  static let scope = "https://www.googleapis.com/auth/calendar.events"
  static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
}
```

- [ ] **Step 2: Register URL scheme in Info.plist**

Add `CFBundleURLTypes` for the redirect scheme Google expects for your chosen flow (match **Google Cloud Console** “Authorized redirect URIs” **exactly**).

- [ ] **Step 3: Handle redirect URL in the running app**

In `FullApp.swift` (or `@main` app struct), use `.onOpenURL` to pass the callback URL into `GoogleCalendarOAuthService` singleton so the pending `ASWebAuthenticationSession` completion can finish (pattern depends on whether you use the session’s built-in callback or a shared continuation).

**Verify:** Build succeeds; with placeholder client ID, tapping Connect should open browser (may error until Console matches—expected).

**Commit:** `chore: add Google Calendar OAuth plist keys and URL scheme`

---

### Task 2: Keychain persistence for Google Calendar OAuth

**Files:**

- Modify: `WhisperShortcut/KeychainManager.swift`
- Modify: `WhisperShortcut/KeychainManaging` protocol in same file

- [ ] **Step 1: Extend protocol**

Add methods, for example:

```swift
func saveGoogleCalendarRefreshToken(_ token: String) -> Bool
func getGoogleCalendarRefreshToken() -> String?
func deleteGoogleCalendarRefreshToken() -> Bool
```

Use a dedicated `accountName` constant (e.g. `google-calendar-refresh-token`).

- [ ] **Step 2: Implement with existing `saveKey` / `getKey` / `deleteKey` helpers**

Mirror `saveGoogleAPIKey` style; reuse `Constants.serviceName` or split service if you want isolation (optional—mirroring is simpler).

- [ ] **Step 3: Manual check**

Run app from Xcode, use a temporary debug button or lldb to save/read/delete a dummy string; confirm Keychain access succeeds.

**Commit:** `feat(keychain): store Google Calendar refresh token`

---

### Task 3: OAuth service (PKCE + ASWebAuthenticationSession + token exchange)

**Files:**

- Create: `WhisperShortcut/GoogleCalendarOAuthService.swift`

- [ ] **Step 1: Implement PKCE helpers**

`generateCodeVerifier()` (URL-safe random 43–128 chars) and `codeChallengeS256(verifier:)` (SHA256, base64url).

- [ ] **Step 2: Build authorization URL**

Query parameters: `client_id`, `redirect_uri`, `response_type=code`, `scope`, `code_challenge`, `code_challenge_method=S256`, `access_type=offline`, `prompt=consent` (first-time refresh token).

- [ ] **Step 3: Start `ASWebAuthenticationSession`**

Use `ASWebAuthenticationSession(url:callbackURLScheme:completionHandler:)`; on success parse `code` from query; exchange POST to `tokenEndpoint` with `grant_type=authorization_code`, `client_id`, `code`, `redirect_uri`, `code_verifier`.

- [ ] **Step 4: Save refresh token via KeychainManager**

Parse JSON response; persist `refresh_token` if present; hold `access_token` in memory or Keychain with expiry (optional for first iteration: always refresh before first API call).

- [ ] **Step 5: Implement `refreshAccessToken()`**

POST `grant_type=refresh_token`, `client_id`, `refresh_token`; return new access token; on `invalid_grant`, clear Keychain and surface “Please connect again” to UI.

**Verify:** Full manual flow: Settings → Connect → Google consent → return to app → `DebugLogger` shows success line **without** printing tokens.

**Commit:** `feat: Google Calendar OAuth PKCE flow`

---

### Task 4: Minimal Google Calendar API client

**Files:**

- Create: `WhisperShortcut/GoogleCalendarAPIClient.swift`

- [ ] **Step 1: Shared request helper**

Method `authorizedRequest(url:httpMethod:body:)` that injects `Authorization: Bearer <access_token>`, calls `refreshAccessToken()` on 401 once, then retries.

- [ ] **Step 2: `listUpcomingEvents(maxResults:timeMin:)`**

`GET https://www.googleapis.com/calendar/v3/calendars/primary/events?...` — parse JSON to a small Swift struct or `[String: Any]` for tool responses.

- [ ] **Step 3: `createEvent(summary:start:end:timeZone:)`**

`POST` to `.../calendars/primary/events` with JSON body `summary`, `start`/`end` as `dateTime` + `timeZone`. Keep MVP: single block event, no attendees in v1.

**Verify:** With connected account, call from a temporary debug action: list returns JSON; create creates visible event in Google Calendar web UI.

**Commit:** `feat: Google Calendar API list and create`

---

### Task 5: Gemini function tools (registry + conditional registration)

**Files:**

- Modify: `WhisperShortcut/GeminiChatTools.swift`
- Modify: `WhisperShortcut/GeminiChatView.swift`

- [ ] **Step 1: Add function declarations** (English descriptions)

Example tool names (adjust to match `execute`):

- `google_calendar_list_events` — parameters: `max_results` (int, default 10), `hours_ahead` (int, default 168).
- `google_calendar_create_event` — parameters: `summary` (string), `start_iso8601` (string), `end_iso8601` (string), `time_zone` (string, default `TimeZone.current.identifier`).

- [ ] **Step 2: Implement `execute` branches**

On missing refresh token, return `["error": "Google Calendar is not connected. Connect it in Settings."]` (English).

On success return compact JSON-friendly dict: `events: [...]` or `event_id`, `html_link`.

Use `@MainActor` where UI or pasteboard touched; API client can run `nonisolated` with `await MainActor` only if needed.

- [ ] **Step 3: Expose `GeminiChatToolRegistry.functionDeclarationsIncludingCalendar(isConnected: Bool)`** or filter in `GeminiChatView` before mapping to `LLMToolDeclaration`.

In `GeminiChatView.swift` around lines 385–390, merge base declarations with calendar declarations when `KeychainManager.shared.getGoogleCalendarRefreshToken() != nil` (or a small `GoogleCalendarOAuthService.shared.isConnected`).

- [ ] **Step 4: Manual chat test**

Prompt: “What’s on my calendar tomorrow?” — model should call list tool; then “Add a 30-minute meeting called Test at 3pm tomorrow” — model should call create.

**Commit:** `feat: Gemini Chat tools for Google Calendar`

---

### Task 6: Settings UI (Connect / Disconnect)

**Files:**

- Create: `WhisperShortcut/Settings/Tabs/OpenGemini/GoogleCalendarConnectionSection.swift` (new, keeps tab small)
- Modify: `WhisperShortcut/Settings/Tabs/OpenGeminiSettingsTab.swift`

- [ ] **Step 1: Section UI**

Buttons: **Connect Google Calendar**, **Disconnect**; status text: “Connected” / “Not connected”. English copy only.

- [ ] **Step 2: Wire Connect** to `GoogleCalendarOAuthService.startAuthorization(presentingWindow:)`

Use `NSApplication.shared.keyWindow` or pass window from settings.

- [ ] **Step 3: Wire Disconnect** to delete Keychain refresh token and clear in-memory session.

**Verify:** Disconnect removes tools from next chat send (re-open chat or next message).

**Commit:** `feat(settings): Google Calendar connect UI`

---

### Task 7: System instruction hint (optional but recommended)

**Files:**

- Modify: wherever `GeminiChatView.buildSystemInstruction()` is defined (search in `GeminiChatView.swift`)

- [ ] **Step 1: When connected**, append one short English paragraph: tools `google_calendar_*` are available; prefer user’s local timezone; confirm destructive actions in text (model behavior).

**Commit:** `chore: document calendar tools in Gemini chat system prompt`

---

### Task 8: Hardening + edge cases

**Files:**

- Modify: files from Tasks 3–6 as needed

- [ ] **Step 1:** Rate-limit or cap `max_results` (e.g. max 50) in tool `execute`.
- [ ] **Step 2:** Validate ISO8601 dates before API call; return structured error in `functionResponse`.
- [ ] **Step 3:** Ensure tool loop cap (`maxToolRounds` in `GeminiChatView`) still sufficient; do not increase without need.
- [ ] **Step 4:** If App Sandbox is re-enabled later, confirm `com.apple.security.network.client` remains true and document any OAuth loopback differences.

**Verify:** Invalid date strings produce readable model-facing errors, no crash.

**Commit:** `fix: validate calendar tool inputs`

---

### Task 9: Build + smoke test (project requirement)

**Files:** none

- [ ] **Step 1:** From repo root run `cd whisper-shortcut && bash scripts/rebuild-and-restart.sh` (see project overview / rebuild-after-change skill).

**Expected:** Build succeeds, app launches.

- [ ] **Step 2:** Run through OAuth + one list + one create from chat.

**Commit:** only if fixing build issues uncovered.

---

## Self-review (plan vs intent)

| Requirement | Task coverage |
|-------------|----------------|
| Normal user only sees consent, not Cloud Console | Task 1 (dev doc in comments / internal README optional—**do not** add unless user asks); Task 3 |
| Gemini drives calendar via tools, not CLI | Tasks 4–5 |
| Secure token storage | Task 2, 3 |
| Settings discoverability | Task 6 |
| Matches existing chat tool architecture | Task 5 + `GeminiChatView` reference |

**Placeholder scan:** None intentional; client ID values live in plist / xcconfig, not “TBD” in code.

**Optional later (separate plan):** Google Tasks API; recurring events; calendar picker; Google OAuth verification for sensitive scopes at scale.

---

## Execution handoff

**Plan complete and saved to** `docs/superpowers/plans/2026-04-22-gemini-google-calendar-integration.md`.

**Two execution options:**

1. **Subagent-driven (recommended)** — fresh subagent per task, review between tasks.  
2. **Inline execution** — run tasks in this session with checkpoints.

**Which approach do you want?**
