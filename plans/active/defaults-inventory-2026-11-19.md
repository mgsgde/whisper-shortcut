# Defaults inventory — what a fresh install has switched on (2026-11-19)

Status: **report only, nothing changed.** Basis for the owner's decision on defaults
(„so gut wie möglich, nicht so restriktiv wie möglich“). No default was flipped here.

## How this was measured

- Build: `main` @ `69d74566` (v8.92, build 290), direct (non-App-Store) Debug build.
- Fresh isolated instance: `bash scripts/rebuild-and-restart.sh --sidecar --profile defaults-audit --fresh`
  (own bundle id and container; the user's Dev/Release instances and settings were not touched).
- Walked the Welcome Tour with default choices, read the profile's UserDefaults after it
  (`defaults read com.magnusgoedde.whispershortcut.dev.profile.defaults-audit`), opened Settings,
  then cross-checked every control against the code: `SettingsDefaults`
  (`WhisperShortcut/Settings/Shared/SettingsConfiguration.swift:2356`), `FullApp.swift` first-launch
  writes, `MCP/MCPSettingsCatalog.swift`, every `Settings/Tabs/*` view, and the `?? true` / `@AppStorage`
  fallbacks for keys that live outside `SettingsDefaults`.

**Limits of the walk-through**

- The tour could only be driven up to the permissions step on both paths: *Continue* is gated on
  Microphone (and on the Dictation-only path also Accessibility). Granting TCC permissions to a test
  bundle was out of scope, so the later steps (Try it / download / glossary / done) are taken from
  code (`Onboarding/*`), not from screenshots.
- A test profile shares the Dev container's **offline models read-only**. That is why the
  screenshots show "Parakeet Ultra ready" and "Qwen3 4B Instruct is ready" and why the All-features
  path shows *Offline* pre-checked. A real new user sees a ~700 MB download there instead, and per
  code (`WelcomeSteps.swift:96-106`) nothing is pre-selected on step 2 when no model is on disk.
- Screenshots of the Settings tabs past *General* were not captured (sidebar navigation by
  synthetic clicks did not land); those rows are from code and are marked "code" below.

## Screenshots (Welcome Tour, fresh profile)

| # | Step | File |
|---|---|---|
| 1 | Mode choice — **"Dictation only" is pre-selected** | [01-mode-choice.png](defaults-inventory-2026-11-19/01-mode-choice.png) |
| 2 | Dictation-only → "Your language" (preset from macOS language, no Auto) | [02-dictation-only-language.png](defaults-inventory-2026-11-19/02-dictation-only-language.png) |
| 3 | Dictation-only → "Allow access": Microphone **and** Accessibility, Continue locked | [03-dictation-only-permissions.png](defaults-inventory-2026-11-19/03-dictation-only-permissions.png) |
| 4 | Mode choice with "All features" picked | [04-all-features-selected.png](defaults-inventory-2026-11-19/04-all-features-selected.png) |
| 5 | All features → "How should dictation run?" Offline/Cloud, Offline Mode toggle **off** | [05-all-features-dictation-run.png](defaults-inventory-2026-11-19/05-all-features-dictation-run.png) |
| 6 | All features → "macOS permissions": **Fn on**, **Auto-paste off** (until Accessibility) | [06-all-features-permissions.png](defaults-inventory-2026-11-19/06-all-features-permissions.png) |
| 7 | Settings → General after the Dictation-only path | [07-settings-general-dictation-only.png](defaults-inventory-2026-11-19/07-settings-general-dictation-only.png) |

## Headline findings

1. **The default path is "Dictation only", and it switches Offline Mode ON.** Step 1 pre-selects
   "Dictation only" (screenshot 1). Continuing writes `dictationOnlyMode = 1`, `offlineModeEnabled = 1`,
   `selectedTranscriptionModel = parakeet-ultra`, `dictateMode = live`, and moves Dictate Prompt /
   Chat / summary models to on-device Qwen3 4B (`DictationOnlyMode.swift:225-265`; observed in the
   profile's UserDefaults). A user who clicks *Continue* through the tour gets an offline,
   dictation-only app with Chat, Meetings, Dictate Prompt, Read Aloud, Templates, Screenshot and
   AI-apps tabs hidden. The onboarding never tells them that Offline Mode was turned on.
2. **No onboarding step asks for any of the "smart" opt-ins**: Text around cursor, Front window
   picture, Save usage data, Writing Style, AI apps (MCP), Launch at Login. The only opt-ins the tour
   shows are Fn, Auto-paste, Offline Mode (All-features path) and usage statistics (All-features
   *done* step only).
3. **"Save usage data" is off and silently disables five features** (all gated on
   `ContextLoggingPreference.isEnabled`): the interaction log, the on-disk *Recent Transcriptions*
   history (`TranscriptionHistoryStore.swift:96-98` — the menu keeps them in memory only, lost on
   quit), the glossary fast-learner (`GlossaryFastLearner.swift:46-48`), learned quick prompts
   (`QuickActionStore.swift:228`, although their own toggle defaults to **on**), and Chat's
   `read_recent_interactions` / tuning-from-usage (`ChatTools.swift:1693`, `ChatView.swift:2104`).
   It also blocks "Let AI apps read my recent dictations".
4. **Some defaults are already generous**, and they are on without asking: Claude web search
   (billed per search), Dictate Prompt read-only tools, learned quick prompts, Read Aloud smart
   rewrite, automatic update checks, the hallucination filter, and Fn dictation when the 🌐 key is free.

## Inventory

Legend — **Onb.**: is the choice shown in the Welcome Tour (Y = yes, N = no, Y\* = only on one path).
**Why off** classes: *Privacy*, *App Store* (guideline), *Cost*, *Hardware*, *UX*, *—* (on by default).
"Adv" = inside a collapsed `AdvancedSettingsGroup`. Direct = `#if !APP_STORE` only.

### Onboarding-level switches

| Area | Setting | Default (fresh) | Onb. | What it unlocks | Why off / note |
|---|---|---|---|---|---|
| Mode | Dictation only (`dictationOnlyMode`) | **pre-selected in tour → ON** after Continue; `false` if the key is never written (`UserDefaultsKeys.swift:195`) | Y | Off = Chat, Meetings, Dictate Prompt, Read Aloud, Templates, Screenshot, AI apps | Tour pre-selects it (`DictationOnlySteps.swift:23-60`); plan `dictation-only-mode.md` decision 2 "default false. Existing installs do not change." — the key default is false, the *tour* default is true |
| Privacy | Offline Mode (`offlineModeEnabled`) | **ON via Dictation-only path** (not shown there); OFF on All-features path (toggle on step 2) | Y\* | Off = any cloud provider, telemetry, Save usage data, MCP server | No comment states why the key is off; Dictation-only applies it as part of its preset. *UX* |
| Dictate | Transcription model | Dictation-only: Parakeet Ultra (offline). All features: Offline → Parakeet Ultra, Cloud → `gpt-transcribe` (`SettingsDefaults.selectedTranscriptionModel`), reconciled to the provider the user has a key for | Y | — | — |
| Dictate | Mode Dictate/Live (`dictateMode`) | `.dictate` by key; **`.live`** after Dictation-only (direct build, Apple Silicon) | N | — | — |
| Dictate | Language | macOS language (Dictation-only, no Auto); Auto → Mac language on All-features offline path | Y | — | — |
| Shortcut | Fn dictation (`fnKeyDictation`) | **ON** in direct build when 🌐 key is "Do Nothing" (`SettingsConfiguration.swift:2465-2471`); off in App Store | Y\* (All features; Dictation-only only when the 🌐 key conflicts) | — | Needs Accessibility; without it the toggle is on but inert (screenshot 7 shows "Fn needs Accessibility") |
| Clipboard | Auto-paste (`autoPasteAfterDictation`) | Follows Accessibility when unset: off until granted, **on once granted** (`AutoPasteDefault`, `:2556-2584`); App Store always off | Y\* (All features) | Text lands at the cursor via ⌘V | *App Store* 2.4.5 — `SettingsConfiguration.swift:2444-2448` |
| Privacy | Share anonymous usage statistics (`telemetryEnabled`) | OFF | Y\* (All-features *done* step only; not on Dictation-only path) | Opt-in telemetry pings | *Privacy* — `plans/active/opt-in-telemetry.md:47` "Decision (Magnus, 2026-09-29): … off by default" |

### General

| Area | Setting | Default | Onb. | What it unlocks | Why off |
|---|---|---|---|---|---|
| Shortcuts | Dictate ⌃⌥1, Dictate Prompt ⌃⌥2, Screenshot ⌃⌥3, Open Chat ⌥Space, Open Settings ⌃⌥0, Read Aloud ⌃⌥4, Read Aloud Prompt ⌃⌥⇧4 | ON (`ShortcutConfig.swift:256-271`); Dictation-only unregisters all but Dictate / Dictate Live / Add to Glossary / Open Settings | Y\* (Dictate recorder on All-features *done*) | — | — |
| Shortcuts | Add to Glossary ⌃⌥7 (direct) | OFF ("Not set") | N | Select text → glossary with one key | *UX* — `ShortcutConfig.swift:245` "Ships disabled: … only the suggested binding" |
| Shortcuts | Dictate Live ⌃⌥5 (direct) | OFF ("Not set") | N | Streaming dictation on its own key | *App Store*/*UX* — `:248-249` "direct download only (it pastes, which needs Accessibility)" |
| Startup | Launch at Login | OFF | N | App is there after reboot | *App Store* 2.4.5(iii) — `FullApp.swift:242-244` "must never register itself for auto-launch without user consent" |
| Updates | Check automatically (Sparkle, direct) | ON, daily | N | — | — (`Info.plist:112-119`; not in Dev builds) |
| Updates | Channel | Stable | N | Latest = new builds immediately | *UX* — `UpdatesSection.swift:65-66` |
| Notifications | Show popups | ON, centre-bottom, 3 s, errors 30 s | N | — | — |
| Clipboard | After auto-paste: Leave / Restore / Empty | Leave | N | Restore old clipboard, or clear it (medical) | *UX* — `SettingsConfiguration.swift:2450-2455` |
| Window (Adv) | Close Settings on click outside | OFF | N | — | *UX* — `:2408-2410` |
| Window (Adv) | Dock icon | OFF | N | ⌘-Tab reachability | *UX* — menu-bar app (`:2411-2413`) |
| Safeguard (Adv) | Ask when recording longer than | 5 min | N | — | — |
| Data (Adv) | Save raw assistant responses | OFF | N | Markdown-bug repro files | *Other (diagnostics)* — `UserDefaultsKeys.swift:174-176` |

### Dictate

| Area | Setting | Default | Onb. | What it unlocks | Why off |
|---|---|---|---|---|---|
| Accuracy (Adv) | Temperature / thinking effort | verbatim / minimal | N | — | — (latency, `:2394-2397`) |
| Hallucinations (Adv) | Filter known silence hallucinations | ON (WhisperKit only) | N | — | — |
| Names (Adv, direct) | Use names from the field as spelling hints (`dictateFieldHintEnabled`) | OFF | N | GPT Transcribe spells names already on screen | *Privacy* — `:2426-2427` "the field text leaves the Mac … so it is opt-in"; `plans/active/dictate-field-hint.md:90` |
| Glossary | Glossary / Additional instructions | empty | Y\* (Dictation-only step 106 adds one word) | — | — |
| Models | Offline model rows | none downloaded | Y (step 2 / download step) | Qwen3 ASR 1.7B | *Hardware* — ≥32 GB, Apple Silicon (`Qwen3ModelManager.swift:63-84`) |

### Dictate Prompt (hidden in Dictation-only)

| Area | Setting | Default | Onb. | What it unlocks | Why off |
|---|---|---|---|---|---|
| Model | Dictate Prompt model | Gemini 3.8 Flash (`SettingsDefaults.selectedPromptModel`); Qwen3 4B in offline/Dictation-only | N | larger MLX models | *Hardware* — Qwen3.5 9B ≥16 GB, Gemma 26B ≥32 GB (`LocalLLMModelManager.swift:86-99`) |
| Screen Context (direct) | **Text around cursor** (`promptSendsFocusedFieldText`) | OFF, consent alert | N | Prompt sees up to 3000 chars before / 1000 after the cursor | *Privacy* — `SettingsConfiguration.swift:2479-2480` "Explicit opt-in (same reason)"; `SpeechToPromptSettingsTab.swift:179` |
| Screen Context (direct) | **Front window picture** (`screenshotInPromptMode`) | OFF, consent alert | N | Picture of the front window when the field is empty/short/unreadable | *Privacy* — `:2475-2478` "nothing from the screen except the user's own selection may leave the Mac without consent" |
| Quick Prompts | Also show prompts you use often | **ON** (`?? true`, `QuickActionStore.swift:240-243`) — but inert while Save usage data is off (`:228`) | N | Learned prompt chips | — (effectively off: depends on Save usage data) |
| Look things up | Let Dictate Prompt use read-only tools | **ON** (`?? true`, `DictatePromptAgent.swift:56-58`) | N | Lookups in connected services (Gemini only) | — |
| Writing Style | Use my writing style (`writingStyleEnabled`) | OFF | N | Gmail import + learning from dictations into mail/messenger apps; style profile applied to Dictate Prompt | *Privacy*/*UX* — `UserDefaultsKeys.swift:230-231`; `plans/active/writing-style.md:6,10,98` "default off until Slice 2 proves itself"; turning it on is the consent to import sent mail |
| Writing Style | Writing Style model | Gemini 3.8 Flash | N | — | — |

### Templates, Screenshot, Read Aloud (hidden in Dictation-only)

| Area | Setting | Default | Onb. | What it unlocks | Why off |
|---|---|---|---|---|---|
| Templates | Template list / picker shortcut | none / not registered | N | Spoken templates | — (empty by nature) |
| Screenshot | Save screenshots to a folder | OFF | N | Keeps captures on disk | *UX* — needs a folder pick (security-scoped bookmark) |
| Read Aloud | Model | Gemini 3.8 Flash-Lite TTS; macOS voice in offline | N | Qwen3 TTS | *Hardware* — CustomVoice ≥16 GB, VoiceDesign ≥32 GB |
| Read Aloud | Smart rewrite before speaking | ON | N | — | — |
| Read Aloud | Speed | 1.0× | N | — | — |

### Chat (hidden in Dictation-only)

| Area | Setting | Default | Onb. | What it unlocks | Why off |
|---|---|---|---|---|---|
| Model | Chat model | Gemini 3.8 Flash | N | — | — |
| Appearance | Font / follow new text | Sans / ON | N | — | — |
| Web search | Let Claude search the web | **ON** (`?? true`, `AnthropicChatProvider.swift:30-33`) | N | — | — (billed per search; switch exists for that, `ClaudeWebSearchSection.swift:4-5`) |
| Workspace | Shared folders | none | N | Chat reads files in chosen folders | — |
| Workspace | Let the chat create and change files | OFF (visible once a folder is shared) | N | Write access in shared folders | *Privacy/safety* — `UserDefaultsKeys.swift:137-138` "Off unless the user turns it on" |
| Window (Adv) | Close Chat on click outside | ON | N | — | — |

### Meetings (hidden in Dictation-only)

| Area | Setting | Default | Onb. | What it unlocks | Why off |
|---|---|---|---|---|---|
| Models | Meeting transcription / summary | same as Dictate / Gemini 3.5 Flash-Lite | N | — | *Cost* — Flash-Lite because it runs often (`SettingsConfiguration.swift:2378-2381`) |
| Adv | Chunk interval / safeguard | 60 s / 90 min | N | — | *Cost* — 60 s halves API calls (`:2483-2485`) |
| — | Auto-detect / auto-record meetings | **does not exist** | — | — | — |

### Claude & AI Apps (hidden in Dictation-only)

| Area | Setting | Default | Onb. | What it unlocks | Why off |
|---|---|---|---|---|---|
| MCP | Allow AI apps on this Mac to connect (`mcpServerEnabled`) | OFF; never starts in Offline Mode, Dictation-only or a sidecar | N | Claude/Cursor read meetings, settings, live transcript | *Privacy/security* — `AIAppsSettingsTab.swift:12` "Off by default."; `plans/active/mcp-meeting-server.md:39` |
| MCP | AI apps may: read / propose / change | read | N | Settings changes by AI apps | *Privacy/security* — `MCPConfigApplier.swift:7-9` |
| MCP | Let AI apps read my recent dictations | OFF, disabled unless Save usage data is on | N | Tuning from Claude Code | *Privacy* — `UserDefaultsKeys.swift:386` |

### Accounts

No toggles. All keys empty, Google / Trello / mail accounts not connected; ChatGPT-plan sign-in
direct build only (*App Store / provider policy*, `AccountsSettingsTab.swift:30-37`).

### Permissions & Privacy

| Area | Setting | Default | Onb. | What it unlocks | Why off |
|---|---|---|---|---|---|
| Privacy | Offline Mode | see onboarding table (ON after Dictation-only) | Y\* | — | — |
| Privacy | Share anonymous usage statistics | OFF; forced off in Offline Mode | Y\* | Product metrics | *Privacy* — owner decision 2026-09-29 |
| Privacy | **Save usage data** (`contextLoggingEnabled`, raw key `userContextLoggingEnabled`) | OFF (written on first launch, `FullApp.swift:236-240`); section hidden in Dictation-only, disabled in Offline Mode | N | Interaction log; on-disk Recent Transcriptions; glossary fast-learner; learned quick prompts; Chat `read_recent_interactions` + "tune from usage"; AI apps reading recent dictations | *Privacy* — owner decision 2026-10-19 (`plans/ux-review-2026-10-19.md:32,128,140`: "off — matches the privacy promise"; Magnus: „Ja, bau die Entscheidungen 1–7 wie empfohlen.“) |

### Kill switches with no UI (on unless written)

`speechActivityGateEnabled` (on), `mcpAutoRepairClientTokens` (on), `qwen3TTSPrebufferDisabled` (false),
`telemetryForceDisabled` (admin key). `improveFromUsageAutoRunInterval` is forced to 0 on every
launch to keep pre-removal builds from rewriting the glossary (`FullApp.swift:247-252`).

## Observed UserDefaults after the Dictation-only tour (fresh profile)

```
dictationOnlyMode = 1
offlineModeEnabled = 1
selectedTranscriptionModel = parakeet-ultra        (meetings: parakeet-ultra)
selectedPromptModel / selectedOpenGeminiModel / selectedMeetingSummaryModel /
selectedImprovementModel = local-mlx-qwen3-4b-instruct-2507
selectedReadAloudModel = system-macos
dictateMode = live
whisperLanguage = en        punctuationMode = automatic
userContextLoggingEnabled = 0
improveFromUsageAutoRunInterval = 0
```

(`whisperLanguage = en` because the test Mac's macOS language is English; a German Mac gets `de`
and `punctuationMode = spokenOnly`, `DictationOnlyMode.swift:256, 323-325`.)

## Where the decision sits (no proposal, only the open questions)

- Whether the tour should keep **pre-selecting "Dictation only"** (and with it Offline Mode, Live
  mode and on-device Dictate Prompt) for a user who just clicks *Continue*.
- Whether **Save usage data** stays off given that it silently disables Recent-Transcriptions
  persistence, the glossary fast-learner and learned quick prompts (whose own toggle is "on").
- Whether **Text around cursor / Front window picture / Writing Style** should be offered in the
  tour (today: Settings only, behind a consent alert).
