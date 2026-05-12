# OpenAI as First-Class Provider — Phase 1 (Transcription)

## Goal

Add OpenAI's transcription models as proper `TranscriptionModel` cases (parallel to Gemini and offline Whisper), gated on an OpenAI API key configured in General settings. Reframe the existing "Custom Transcription API" entry as "Self-hosted Transcription Endpoint" for users running their own OpenAI-compatible servers (Cloudflare-fronted, faster-whisper-server, etc.).

This is the first of three phases that gradually bring OpenAI up to parity with Google (Gemini) and xAI (Grok). Phase 1 is transcription-only. Phase 2 will add OpenAI to Dictate Prompt. Phase 3 will add OpenAI to Chat (the largest scope).

## Context

- Today's transcription model picker offers Gemini models (cloud), offline Whisper variants (local WhisperKit), and a single "Custom Transcription API" entry that wraps any OpenAI-compatible `/v1/audio/transcriptions` endpoint.
- "Custom Transcription API" was originally added in PR #25 as a backdoor to OpenAI (its default endpoint is `https://api.openai.com/v1/audio/transcriptions`). The Phase 1 work makes the OpenAI case explicit and reframes the custom entry as what it really is: a self-hosted/proxy escape hatch.
- Settings already contain dedicated API key sections for Google and xAI. OpenAI is the missing third row.
- The Smart Improvement audio verification system classifies models into asymmetry tiers and uses Gemini to verify non-Gemini transcripts. OpenAI is a different family from Gemini, so Gemini-based Smart Improvement can informatively verify OpenAI transcripts (same logic that already handles offline Whisper).
- Verified via the official `openai-python` SDK source (`src/openai/types/audio/transcription_create_params.py`): OpenAI's current transcription model IDs are `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-mini-transcribe-2025-12-15`, `whisper-1`, and `gpt-4o-transcribe-diarize`.

## Non-Goals

- No changes to Dictate Prompt or Chat. Those are Phase 2 and Phase 3.
- No deprecation of offline Whisper or Gemini transcription models.
- No removal of the Self-hosted endpoint feature. It continues to serve self-hosted-Whisper users; the rename clarifies its purpose.
- No diarization support (`gpt-4o-transcribe-diarize`). The app is a single-speaker dictation tool.
- No dated-snapshot model IDs (`gpt-4o-mini-transcribe-2025-12-15`). End-user apps use floating IDs to pick up upstream improvements automatically.
- No `whisper-1` legacy model. `gpt-4o-mini-transcribe` covers the cheap-tier use case better.

## Locked Decisions

- **Models in scope:** `gpt-4o-transcribe` and `gpt-4o-mini-transcribe`.
- **Self-hosted entry renamed to:** "Self-hosted Transcription Endpoint".
- **Self-hosted configuration UI:** stays under the model picker in the Dictate tab, visible only when its model entry is selected. Same conditional pattern as the existing Custom Transcription API section.
- **OpenAI API key location:** General settings, between xAI API key and Keyboard Shortcuts.

## Architecture

### Multipart transcription helper

Refactor `SpeechService.transcribeWithCustomTranscriptionAPI(audioURL:)` into a parametrized helper that both the OpenAI dispatch and the Self-hosted dispatch can call:

```swift
private func transcribeViaOpenAICompatibleEndpoint(
  audioURL: URL,
  endpoint: URL,
  modelID: String,
  bearerToken: String,
  extraHeaders: [[String: String]] = []
) async throws -> String
```

- OpenAI dispatch (new): calls helper with `AppConstants.openAITranscriptionsEndpoint`, the selected model's API ID, and `KeychainManager.getOpenAIAPIKey()`.
- Self-hosted dispatch (existing, repointed): calls helper with the user-configured endpoint, model ID `"whisper-1"` (or the fallback `audio_file` layout for non-OpenAI servers), bearer token from Keychain, and custom headers from Keychain.

Whisper Glossary + language passthrough stays inside the helper and applies to both call sites unchanged.

### TranscriptionModel cases

Add two new cases. Keep their `rawValue`s distinct from the OpenAI API model IDs so the persisted UserDefaults identifier is independent from the upstream model ID — gives us room to repoint a label without UserDefaults migration:

```swift
case openAIGPT4oTranscribe       = "openai-gpt-4o-transcribe"
case openAIGPT4oMiniTranscribe   = "openai-gpt-4o-mini-transcribe"
```

A new property `apiModelID: String?` returns the upstream OpenAI API ID for these two cases (`gpt-4o-transcribe` / `gpt-4o-mini-transcribe`), `nil` elsewhere.

### Self-hosted case: Swift-level rename only

Rename the Swift identifier from `customTranscriptionAPI` to `selfHostedTranscription` for clarity, **but keep the rawValue `"custom-transcription-api"` stable** so persisted UserDefaults for any (rare) early adopter still resolve. Same trick used elsewhere in this file (display label decoupled from raw value).

```swift
case selfHostedTranscription = "custom-transcription-api"
```

`AsymmetryClass.customTranscriptionAPI` likewise becomes `AsymmetryClass.selfHostedTranscription`. The persisted backend tag in the audio capture log changes from `"custom"` to `"self-hosted"` — acceptable break since the field is freshly introduced and only consumed by Smart Improvement's audio verification, not by any user-visible feature.

### AsymmetryClass extension

Add a new tier for OpenAI audio:

```swift
enum AsymmetryClass: Int {
  case offlineWhisper
  case openAIAudio              // NEW
  case selfHostedTranscription  // renamed from customTranscriptionAPI
  case geminiFlashLite
  case geminiFlash
  case geminiPro
}
```

Extend `canInformativelyVerify`:

```swift
switch transcriptionModel.asymmetryClass {
case .offlineWhisper, .openAIAudio, .selfHostedTranscription:
  return self.isGemini
default:
  ...
}
```

### Backend tag in ContextLogger

`MenuBarController.performTranscription` already has a three-way conditional. Extend to four:

| Model kind | Tag |
|---|---|
| Offline Whisper | `"whisper"` |
| OpenAI (both new cases) | `"openai"` |
| Self-hosted (existing) | `"self-hosted"` (renamed from `"custom"`) |
| Gemini (everything else) | `"gemini"` |

## Files

### New

- `WhisperShortcut/Settings/Tabs/General/OpenAIAPIKeySection.swift` — modelled directly after `XAIAPIKeySection.swift`. SecureField for `sk-…` key, show/hide toggle, save to Keychain on change. No proxy detection or fancy validation; treat empty string as "no key configured".

### Modified

- `WhisperShortcut/KeychainManager.swift`
  - Protocol methods: `saveOpenAIAPIKey(_:)`, `getOpenAIAPIKey()`, `deleteOpenAIAPIKey()`, `hasValidOpenAIAPIKey()`.
  - Constants: `openAIAccountName = "openai-api-key"`.
  - Cache: `cachedOpenAIAPIKey: String?`.
  - Implementation mirrors the existing xAI block.

- `WhisperShortcut/TranscriptionModels.swift`
  - Two new cases (see Architecture).
  - `displayName`: "OpenAI GPT-4o Transcribe" / "OpenAI GPT-4o Mini Transcribe".
  - `description`: short cost/accuracy hint per model.
  - `costLevel`: `"Medium"` for `gpt-4o-transcribe`, `"Low"` for `gpt-4o-mini-transcribe`.
  - `apiEndpoint`: `AppConstants.openAITranscriptionsEndpoint` for both.
  - `isRecommended`: `false` for both (let users choose).
  - `apiModelID: String?`: returns the upstream OpenAI API ID.
  - `isGemini`: `false` for both.
  - `isOffline`: `false` for both.
  - `asymmetryClass`: `.openAIAudio` for both.
  - Swift case rename `customTranscriptionAPI` → `selfHostedTranscription` (raw value preserved).

- `WhisperShortcut/SpeechService.swift`
  - New private helper `transcribeViaOpenAICompatibleEndpoint(...)` — extracted from `transcribeWithCustomTranscriptionAPI`.
  - New dispatch branch in `transcribe(audioURL:)`: `if let modelID = model.apiModelID, model.asymmetryClass == .openAIAudio { ... helper call with OpenAI endpoint + key ... }`. Throws a clear `noOpenAIAPIKey`-style error when key missing.
  - Existing `transcribeWithCustomTranscriptionAPI` becomes a thin wrapper that resolves the user-configured endpoint/token/headers and calls the helper.
  - Same logging prefix `CUSTOM-TRANSCRIPTION:` is renamed to `OPENAI-TRANSCRIPTION:` for the OpenAI path and `SELF-HOSTED-TRANSCRIPTION:` for the self-hosted path so log filtering is precise.

- `WhisperShortcut/Settings/Tabs/GeneralSettingsTab.swift`
  - Embed `OpenAIAPIKeySection(viewModel: viewModel)` between `XAIAPIKeySection` and `KeyboardShortcutsSection`, separated by `SpacedSectionDivider`.

- `WhisperShortcut/Settings/Tabs/SpeechToText/CustomTranscriptionAPISection.swift`
  - File rename → `SelfHostedTranscriptionEndpointSection.swift`.
  - Struct rename → `SelfHostedTranscriptionEndpointSection`.
  - UI strings updated: title → "Self-hosted Transcription Endpoint", subtitle reframed for the self-hosted use case (no longer reads as the OpenAI default since OpenAI has its own dedicated entry now).
  - The "Leave empty to use OpenAI's default endpoint" hint is removed — for a self-hosted entry, an empty URL is invalid. Add validation: refuse to dispatch if URL is empty.

- `WhisperShortcut/Settings/Tabs/SpeechToTextSettingsTab.swift`
  - Conditional render check updates from `== .customTranscriptionAPI` to `== .selfHostedTranscription`.
  - Reference renamed section.
  - Make OpenAI model entries disabled in the picker when `!KeychainManager.shared.hasValidOpenAIAPIKey()` and surface an inline hint similar to the existing Gemini-no-key message.

- `WhisperShortcut/Settings/Components/ModelSelectionView.swift`
  - Per-model availability gating: pass `openAIDisabled: Bool` flag similar to existing `geminiDisabled`.

- `WhisperShortcut/MenuBarController.swift`
  - Backend tag conditional extended to four branches (see Architecture).
  - Rename `"custom"` → `"self-hosted"`. (Affects only newly captured audio metadata, not user-visible.)

- `WhisperShortcut/SettingsConfiguration.swift` (if needed)
  - Add a default for the selected transcription model fallback. Existing default is fine; no change unless the loadSelected migration needs to map old IDs.

- `WhisperShortcut/UserDefaultsKeys.swift`
  - No new keys. The OpenAI key lives in Keychain, not UserDefaults. The self-hosted endpoint URL key keeps its name (`customTranscriptionAPIURL`) — internal-only.

### Renamed

- `Settings/Tabs/SpeechToText/CustomTranscriptionAPISection.swift` → `Settings/Tabs/SpeechToText/SelfHostedTranscriptionEndpointSection.swift`

## Implementation Plan

1. **Keychain.** Add OpenAI key methods to `KeychainManaging` protocol and `KeychainManager`. Mirror the xAI block exactly.

2. **TranscriptionModel.** Add the two new OpenAI cases. Add `apiModelID` property. Update every switch in the file (cases for `displayName`, `description`, `costLevel`, `apiEndpoint`, `isGemini`, `isOffline`, `isRecommended`, `asymmetryClass`). Add `.openAIAudio` to the `AsymmetryClass` enum. Extend `canInformativelyVerify`.

3. **TranscriptionModel rename.** Swift case `customTranscriptionAPI` → `selfHostedTranscription` (raw value `"custom-transcription-api"` preserved). Update all references: `SpeechService.swift`, `MenuBarController.swift`, `Settings/Tabs/SpeechToText/SelfHostedTranscriptionEndpointSection.swift`. Rename `AsymmetryClass.customTranscriptionAPI` → `.selfHostedTranscription`.

4. **SpeechService refactor.** Extract `transcribeViaOpenAICompatibleEndpoint(audioURL:endpoint:modelID:bearerToken:extraHeaders:)` from the current `transcribeWithCustomTranscriptionAPI` body. The helper handles bare-host probing only when called via the self-hosted path (OpenAI's URL is always fully qualified). Glossary + language passthrough stay inside the helper.

5. **SpeechService dispatch.** Add an OpenAI branch in `transcribe(audioURL:)`. Throw a typed error with a friendly user-facing message when `getOpenAIAPIKey()` is empty ("OpenAI API key is missing — set it in General settings").

6. **Self-hosted section rename.** Move the file. Rename the struct. Update UI strings. Add the empty-URL validation (refuse dispatch + show inline error). Update the embed point in `SpeechToTextSettingsTab.swift`.

7. **General settings.** New `OpenAIAPIKeySection`. Embed between xAI and Keyboard Shortcuts.

8. **Model picker gating.** Pass `openAIDisabled` into `ModelSelectionView`. Show an inline message "Add your OpenAI API key in the General tab to enable these models" similar to the existing Gemini-no-key message.

9. **MenuBarController backend tag.** Four-way conditional. Rename `"custom"` → `"self-hosted"`.

10. **Logging.** Split `CUSTOM-TRANSCRIPTION:` into `OPENAI-TRANSCRIPTION:` and `SELF-HOSTED-TRANSCRIPTION:`. Update CLAUDE.md's "DebugLogger Categories" section to list both.

11. **Build, manual verify.** Rebuild, open settings, add an OpenAI key, pick `gpt-4o-transcribe`, dictate, verify the log says `OPENAI-TRANSCRIPTION: POST https://api.openai.com/v1/audio/transcriptions (model: gpt-4o-transcribe, language: …, prompt: …)` and that the transcription appears.

12. **Commit & push.** One coherent commit: "Add OpenAI as a first-class transcription provider".

## Smart Improvement Compatibility

- OpenAI captures still feed the audio verification pool, tagged `backend=openai`. Gemini SI verification informativeness reads from `AsymmetryClass.openAIAudio` → `Gemini can verify`. Same shape as offline-Whisper.
- The `validate-audio-verification` skill needs no changes for Phase 1; its log filters look for `AUDIO-VERIFY:` prefixes which remain unchanged.
- The Whisper Glossary derived from Smart Improvement keeps applying because it's forwarded as the `prompt` field — same passthrough as today.

## Risks / Open Questions

1. **`gpt-4o-transcribe` `prompt` field semantics.** OpenAI docs note `prompt` is supported across all transcription models, but the GPT-4o variants are LLM-style and may handle long glossaries differently than Whisper. Mitigation: trim glossary to ~224 tokens before sending (existing OpenAI documented cap for `whisper-1`). Out of Phase 1 scope; revisit if users report odd biasing behavior.

2. **Pricing volatility.** `costLevel` labels are best-effort. OpenAI has cut prices several times; the labels should not turn into hard truth. Mitigation: cost labels stay qualitative ("Low", "Medium"), never specific dollar values.

3. **Failed migration of selected model.** If a user already had `customTranscriptionAPI` selected and we keep that rawValue, they should keep working after Phase 1. Confirmed in Architecture section. No migration entry needed.

4. **Model picker length.** With OpenAI added, the picker now lists 6 Gemini + 2 OpenAI + 5 offline Whisper + 1 Self-hosted = 14 entries. Acceptable for now. Grouping/section headers in the picker are a future-Phase concern, not Phase 1.

5. **Self-hosted bearer token reuse.** The current Custom-section Keychain methods (`saveCustomTranscriptionBearerToken` etc.) stay named after "custom" even though the user-facing label says "self-hosted". A future cleanup PR can rename. Phase 1 leaves them alone to keep the diff focused.

6. **OpenAI auth error reporting.** OpenAI returns `401 invalid_api_key` with a structured JSON body. Surface that in the user-facing banner rather than the generic "Network error" — minor UX win, easy to do.

## Completion Criteria

- OpenAI key field exists in General settings, persists across app launches.
- Two new OpenAI transcription models appear in the Dictate model picker, disabled until the key is set, enabled once it is.
- Selecting an OpenAI model and dictating produces a correct transcription via `https://api.openai.com/v1/audio/transcriptions` with the model ID forwarded as the `model` form field, language and glossary forwarded as `language` and `prompt`.
- The previously named "Custom Transcription API" entry now reads "Self-hosted Transcription Endpoint" everywhere in the UI, but persisted user data still resolves.
- Smart Improvement audio verification continues to work; new captures are tagged `backend=openai` (or `backend=self-hosted` for the legacy custom path).
- A single commit lands the change. No regressions in existing Gemini or offline-Whisper paths verified by a quick manual dictation with each.
