# Plan: OAuth2 / Google Sign-In as Alternative to API Key

**Goal:** Let non-technical users use WhisperShortcut without entering a Google API key by signing in with their Google account. API key remains supported for users who prefer it.

**Scope:** Gemini API only (transcription, Speech-to-Prompt, Read Aloud, Prompt & Read). No changes to Whisper/local or other non-Gemini flows.

---

## 1. Current State (Summary)

| Component | Current behavior |
|-----------|------------------|
| **KeychainManager** | `getGoogleAPIKey()` / `saveGoogleAPIKey()` only. |
| **GeminiAPIClient** | `createRequest(endpoint, apiKey)` adds `?key=<apiKey>`; `uploadFile(audioURL, apiKey)` same. |
| **SpeechService** | Reads key via `keychainManager.getGoogleAPIKey()`, passes `apiKey` to all Gemini calls. |
| **ChunkTranscriptionService / ChunkTTSService / UserContextDerivation** | Receive `apiKey: String` and pass to `geminiClient.createRequest(..., apiKey)` or similar. |
| **GeneralSettingsTab** | Single “API Key” text field; value synced to Keychain. |

All Gemini requests use **query parameter** auth: `?key=<api_key>`.

---

## 2. Target Behavior

- **Two credential types:** API Key **or** OAuth (Bearer token).
- **Priority:** If an API key is set, use it; else if the user is signed in with Google, use Bearer token.
- **UI:** “Sign in with Google” (and “Sign out”) plus existing API key field. Clear copy that API key is optional when signed in.
- **Billing:** With OAuth, usage is charged to **your** Google Cloud project (the one that owns the OAuth client). Document this and optionally add in-app note.

---

## 3. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Settings UI                                                     │
│  • "Sign in with Google" / "Sign out"                             │
│  • API Key (optional when signed in)                             │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  GoogleAuthService (new)                                         │
│  • Sign in / sign out                                             │
│  • Provide current credential: .apiKey(String) | .oauth(Bearer)  │
│  • Token refresh (Google Sign-In or manual refresh)              │
└──────────────────────────────┬──────────────────────────────────┘
                               │
         ┌─────────────────────┼─────────────────────┐
         ▼                     ▼                     ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐
│ KeychainManager │  │ Token storage   │  │ Google Sign-In SDK       │
│ (API key)       │  │ (OAuth tokens   │  │ (GoogleSignIn-iOS)       │
│                 │  │  in Keychain)   │  │                          │
└─────────────────┘  └─────────────────┘  └─────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  GeminiAPIClient                                                 │
│  • createRequest(endpoint, credential: GeminiCredential)         │
│  • credential = .apiKey(key) → ?key=...                          │
│  • credential = .oauth(accessToken) → Authorization: Bearer ...  │
│  • uploadFile(audioURL, credential) same                         │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  SpeechService / ChunkTranscriptionService / ChunkTTSService /   │
│  UserContextDerivation                                           │
│  • Get credential once from GoogleAuthService (or equivalent)    │
│  • Pass credential (not raw apiKey) to GeminiAPIClient           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Implementation Phases

### Phase 1: Credential abstraction and GeminiAPIClient

**4.1.1** Introduce a single type for “how we authenticate to Gemini”:

- New type (e.g. in `GeminiAPIClient.swift` or `GeminiCredentials.swift`):
  - `enum GeminiCredential { case apiKey(String); case oauth(accessToken: String) }`
- Add:
  - `createRequest(endpoint: String, credential: GeminiCredential) throws -> URLRequest`
  - If `.apiKey(key)`: keep current behavior (`?key=...`).
  - If `.oauth(accessToken)`: no query param, set `Authorization: Bearer <token>`.
- Add overload or replace:
  - `uploadFile(audioURL: URL, credential: GeminiCredential) async throws -> String`
  - Same rule: API key in query vs Bearer in header.
- Keep existing `createRequest(endpoint, apiKey)` (or add a thin wrapper that builds `.apiKey(apiKey)`) so call sites can be migrated incrementally if desired; eventually callers should pass `GeminiCredential` only.

**4.1.2** Replace every internal use of `createRequest(..., apiKey)` and `uploadFile(..., apiKey)` with the credential-based API. Call sites will later pass a `GeminiCredential` from a central “credential provider”.

**Deliverable:** GeminiAPIClient supports both auth methods; no new UI or sign-in yet.

---

### Phase 2: Google Sign-In SDK and token storage

**4.2.1** Add dependency:

- **Google Sign-In for iOS/macOS:** Swift Package `https://github.com/google/GoogleSignIn-iOS` (e.g. 7.0+). Add in Xcode to the app target.

**4.2.2** Google Cloud setup (document for yourself / release):

- One Google Cloud project for the app.
- Enable “Generative Language API”.
- OAuth consent screen (External), add required scopes (e.g. `https://www.googleapis.com/auth/generative-language.retriever` or scope required for Gemini; verify from [Gemini OAuth docs](https://ai.google.dev/gemini-api/docs/oauth)).
- Create OAuth 2.0 Client ID → **Desktop app** (macOS).
- Store **Client ID** in the app (e.g. Info.plist or build config). Client secret for desktop can be embedded or omitted depending on Google’s current guidance for public desktop apps.

**Consent screen (App domain, links):** Google requires these for the OAuth consent screen. For **app verification**, the homepage and privacy policy must be on a **verified domain you own** (GitHub URLs are not accepted as "registered to you"). Use GitHub Pages with a **custom domain** you control:

1. **Site:** This repo includes the app website in `website/` (homepage, privacy policy, terms). Enable GitHub Pages: Settings → Pages → Source: GitHub Actions (workflow in `.github/workflows/pages.yml`).
2. **Custom domain:** In repo Settings → Pages, set a custom domain you control (e.g. `www.whispershortcut.com`). Add the CNAME (or A records) in your DNS.
3. **Verify domain:** In [Google Search Console](https://search.google.com/search-console), add the domain and verify ownership (TXT record). Use the same Google account that is Owner of the GCP project.
4. **Consent screen URLs:** Use the verified domain, e.g.:

| Field | URL (example) |
|-------|----------------|
| Application home page | `https://www.whispershortcut.com/` |
| Application privacy policy link | `https://www.whispershortcut.com/privacy.html` |
| Application Terms of Service link | `https://www.whispershortcut.com/terms.html` |
| Authorised domains | Your verified domain (e.g. `whispershortcut.com`) |

**4.2.3** New `GoogleAuthService` (or `GeminiAuthService`):

- Wraps Google Sign-In: configure with client ID, present sign-in (browser or in-app where supported on macOS).
- On successful sign-in: obtain access token (and refresh token if provided by SDK).
- Persist tokens in Keychain (not UserDefaults): access token, refresh token, expiry. Use a dedicated Keychain account (e.g. `google-oauth-token`) so it’s separate from API key.
- Expose:
  - `currentCredential() -> GeminiCredential?`: if we have a valid (or refreshable) OAuth token, return `.oauth(accessToken)`; else return `nil`.
  - `signIn() async throws` (or callback-based if SDK requires).
  - `signOut()`: clear tokens from Keychain and SDK session.
  - `isSignedIn() -> Bool` for UI.
- **Token refresh:** Before each use (or on 401), refresh if expired using refresh token. If refresh fails, treat as signed out and fall back to API key if available.

**4.2.4** URL handling (macOS):

- Register a custom URL scheme (e.g. `com.magnusgoedde.whispershortcut:/oauth2callback`) and handle it in the app to complete the OAuth redirect. Document in Google Cloud client configuration.

**Deliverable:** User can sign in with Google; tokens stored in Keychain; service can return `.oauth(accessToken)`.

---

### Phase 3: Credential provider and wiring

**4.3.1** Single place that decides “which credential to use for Gemini”:

- Option A: Extend `KeychainManager` with something like `getGeminiCredential() -> GeminiCredential?` that:
  - Uses `getGoogleAPIKey()` first; if non-empty, returns `.apiKey(key)`;
  - Else asks `GoogleAuthService.currentCredential()` and returns `.oauth(accessToken)` if available.
- Option B: New small type `GeminiCredentialProvider` that holds references to `KeychainManager` and `GoogleAuthService` and implements the same logic (API key first, then OAuth).

**4.3.2** Replace “get API key and pass everywhere” with “get credential and pass everywhere”:

- **SpeechService:** Instead of `keychainManager.getGoogleAPIKey()`, use credential provider. If `nil`, show existing “no API key” error. Pass `GeminiCredential` into private methods and into `GeminiAPIClient` / `ChunkTranscriptionService` / `ChunkTTSService`.
- **ChunkTranscriptionService / ChunkTTSService:** Change `apiKey: String` to `credential: GeminiCredential` in the relevant methods; pass through to `GeminiAPIClient`.
- **UserContextDerivation:** Same: accept `GeminiCredential` (or get it from a shared provider) and pass to `GeminiAPIClient`.
- **MenuBarController** `apiKeyUpdated`: extend to “credential updated” (OAuth sign-in/out or API key change) and refresh any UI or state that depends on it.

**Deliverable:** All Gemini calls use `GeminiCredential`; source of truth is “API key if set, else OAuth when signed in”.

---

### Phase 4: Settings UI

**4.4.1** General settings – “Google account” section (above or below API key):

- If not signed in:
  - Primary button: “Sign in with Google”. Triggers `GoogleAuthService.signIn()`; on success, UI updates (e.g. show account email if SDK provides it).
- If signed in:
  - Show short text: “Signed in as …” (email or “Google account” if email not available).
  - Button: “Sign out”. Clears OAuth session and tokens.
- Optional: small info text: “When signed in, your usage is billed to the app’s Google Cloud project.”

**4.4.2** API key section:

- Keep existing text field and Keychain sync.
- Subtitle/copy update: e.g. “Optional when signed in with Google. Required for Gemini if you don’t sign in.”
- Validation / “ready to use” logic: app can use Gemini if either signed in **or** API key is set (and non-empty).

**4.4.3** Error handling:

- If user tries to use a Gemini feature with no credential (no sign-in, no API key): keep current error message (or adjust to “Sign in with Google or add an API key in Settings”).
- If OAuth token is expired and refresh fails: treat as signed out; optionally show a short message “Session expired, please sign in again” and fall back to API key if present.

**Deliverable:** User can sign in/out in Settings; API key remains optional when signed in; copy is clear and in English.

---

### Phase 5: Testing and edge cases

- **Sign in → use transcription / prompt / TTS** → all use Bearer token.
- **Sign out** → next request uses API key if set; otherwise error.
- **API key set, then sign in** → API key takes precedence; requests use API key.
- **Sign in, then remove API key** → still works (OAuth only).
- **Token refresh** → after expiry, refresh token used; if refresh fails, fall back to API key or show “session expired”.
- **No network during sign-in** → clear error.
- **App restart** → persisted tokens in Keychain used; no re-sign-in until expiry or revoke.

**Deliverable:** Test plan executed; edge cases documented or fixed.

---

### Phase 6: Documentation and billing note

- **README or docs:** Short section “Authentication” explaining:
  - Option 1: Sign in with Google (no API key needed; usage billed to app’s project).
  - Option 2: API key (usage billed to the key’s project).
- **In-app:** Optional one-time or dismissible note about billing when user first signs in (e.g. “Usage will be billed to the app’s Google Cloud project”).

**Deliverable:** Docs and (optional) in-app billing note in English.

---

## 5. File and Type Checklist

| Item | Action |
|------|--------|
| `GeminiCredential` enum | Add (e.g. in `GeminiAPIClient.swift` or new `GeminiCredentials.swift`) |
| `GeminiAPIClient` | Add `createRequest(endpoint, credential)`, `uploadFile(audioURL, credential)`; keep or deprecate key-based API |
| `GoogleAuthService` (or `GeminiAuthService`) | New; Sign-In, token storage, `currentCredential()`, `signIn()`, `signOut()` |
| Keychain | New account for OAuth tokens (access + refresh + expiry) |
| `KeychainManager` or new provider | `getGeminiCredential()` (or equivalent) |
| `SpeechService` | Use credential provider; pass `GeminiCredential` internally |
| `ChunkTranscriptionService` | `apiKey` → `credential: GeminiCredential` |
| `ChunkTTSService` | Same |
| `UserContextDerivation` | Same |
| `GeneralSettingsTab` | “Sign in with Google” / “Sign out”, optional billing note, API key copy update |
| `MenuBarController` | React to credential changes (sign-in/out, API key) |
| Info.plist / URL scheme | OAuth redirect URL for macOS |
| Google Cloud Console | OAuth client (Desktop), consent screen, scopes |
| Docs | `docs/` or README: authentication options and billing |

---

## 6. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Google Sign-In SDK API differences on macOS | Follow official “Sign-In for iOS and macOS” docs; test on macOS. |
| OAuth redirect on macOS (no browser or custom scheme) | Use documented redirect URI and custom URL scheme; test sign-in flow on clean install. |
| Token refresh on background/startup | Implement refresh in `GoogleAuthService` before returning `.oauth`; on 401 from Gemini, try refresh once and retry. |
| Billing surprise for developer | Document clearly; optional in-app note; consider quota alerts in GCP. |

---

## 7. Out of scope (for this plan)

- **x-goog-user-project / user-owned billing:** Would require each user to have a GCP project; not suitable for “non-technical users” in this plan.
- **Whisper (local) or other backends:** No change; only Gemini auth is in scope.
- **Multiple Google accounts in-app:** Single “current” account (signed in or not) is enough for v1.

---

## 8. Order of work (summary)

1. **Phase 1:** Credential type + GeminiAPIClient dual auth (no UI, no SDK).
2. **Phase 2:** Add Google Sign-In SDK, OAuth client config, `GoogleAuthService`, token storage and refresh.
3. **Phase 3:** Credential provider and replace all “API key” paths with “credential” in services.
4. **Phase 4:** Settings UI (Sign in / Sign out, API key copy).
5. **Phase 5:** Testing and edge cases.
6. **Phase 6:** Docs and billing note.

After Phase 1, the codebase is ready for OAuth; Phases 2–4 deliver the user-facing feature; 5–6 harden and document it.

---

## 9. Implementation status (branch `feature/oauth-google-sign-in`)

Phases 1–4 are implemented:

- **Phase 1:** `GeminiCredential` enum and credential-based `createRequest` / `uploadFile` in `GeminiAPIClient`.
- **Phase 2:** Google Sign-In SDK (SPM) and `DefaultGoogleAuthService` (with stub when `GIDClientID` is empty). OAuth redirect handled in `FullAppDelegate.application(_:open:)`.
- **Phase 3:** `GeminiCredentialProvider.shared` and all Gemini call sites use credential (SpeechService, ChunkTranscriptionService, ChunkTTSService, UserContextDerivation).
- **Phase 4:** Settings → General: “Google Account” section with “Sign in with Google” / “Sign out” and billing note; API key section subtitle updated.

**To enable Sign in with Google:**

1. Create an OAuth 2.0 Client ID (Desktop app) in [Google Cloud Console](https://console.cloud.google.com/apis/credentials) and enable the Generative Language API.
2. **Where to configure (only place):** In Xcode, open **`WhisperShortcut/Info.plist`** (app target). Set **GIDClientID** to your full Client ID (e.g. `123456789-xxx.apps.googleusercontent.com`).
3. In the same **Info.plist**, under **CFBundleURLTypes** → **CFBundleURLSchemes**, replace `REPLACE_WITH_REVERSED_CLIENT_ID` with your reversed client ID: `com.googleusercontent.apps.` + the part of the Client ID before `.apps.googleusercontent.com` (e.g. `com.googleusercontent.apps.123456789-xxx`).
4. Rebuild; the “Sign in with Google” button in Settings will then open the sign-in flow.

---

## 10. "Unverified app" warning and verification

The consent screen may show: *"The app is requesting access to sensitive info... Until the developer verifies this app with Google, you shouldn't use it."*

**Option A – Use without verification (testing / limited users)**  
- In [Google Cloud Console](https://console.cloud.google.com/) → **APIs & Services** → **OAuth consent screen**, keep the app in **Testing** (do not click "Publish app").  
- Under **Test users**, add the Google accounts that may sign in (e.g. your email and any beta testers; limit e.g. 100).  
- Those users will see the warning but can proceed: **Advanced** → **Go to WhisperShortcut (unsafe)**. No verification request needed.

**Option B – Verify the app (remove warning for all users)**  
1. **OAuth consent screen:** Fill app name, support email, app home page, **privacy policy URL**, and **terms of service** if required. Use a **verified domain** for the app and for the privacy policy.  
2. **Scopes:** Request only the narrowest scopes you need (the app uses `https://www.googleapis.com/auth/generative-language.retriever` for Gemini).  
3. **Publish:** In OAuth consent screen, click **Publish app** so the app is in **Production**.  
4. **Submit for verification:** Click **Prepare for verification** → complete the form → **Submit for verification**.  
5. Provide a **demo video** showing the sign-in flow and how the app uses the requested scope, and a **scope justification** (e.g. "Used to call the Gemini API for transcription and TTS on behalf of the signed-in user").  
6. Google reviews (often a few business days). After approval, the "unverified app" screen is removed for all users.

References: [Submitting your app for verification](https://support.google.com/cloud/answer/13461325), [Verification requirements](https://support.google.com/cloud/answer/13464321).
