# German Localization — App Half

**Status:** Spec only (2026-10-26). Nothing built yet. The website half (routing under `/de`,
`hreflang`, the language switcher) is specified in the private workspace repo, because `web/` lives
there; the two halves share the glossary below and should ship close together.

**Audience:** the Opus session that writes the German copy and checks the layout, and the cheap
hands (Grok 4.7 via `cursor-agent`, Sonnet 5.5 over Grok's cap) that do the plumbing rows.

**Goal:** WhisperShortcut shows its whole interface in German when macOS runs in German, and stays
English everywhere else. English remains the source language and the default. No in-app language
picker: macOS already has one per app (System Settings → General → Language & Region →
Applications).

**Why now:** German-speaking users, including a medical practice piloting Offline Mode, run the app
today in English. The pilot material already has to say "the app is still in English". The App
Store listing is localized into German, so the product page promises a German product that the app
then does not deliver.

---

## 1. What exists today

- No localization at all: no `.xcstrings`, no `.lproj`, `knownRegions = (en, Base)` in
  `project.pbxproj`, one stray `String(localized:)` in the whole target.
- The project is ready for it: `objectVersion = 77` with file-system-synchronized groups (a new
  `Localizable.xcstrings` under `WhisperShortcut/` is picked up without editing the project file),
  `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`, `SWIFT_EMIT_LOC_STRINGS = YES` on the app targets.
- 261 Swift files, ~82k lines.

### How many user-visible strings

Counted on 2026-10-26 (`f4ca78f9`) with two heuristics:

| Measure | Count |
| --- | --- |
| UI call sites with a literal: `Text("…")` 294, `Button("…")` 114, `title: "…"` 152, `subtitle/description/message/detail/hint/caption: "…"` 94, `.help("…")` 60, `Label("…")` 45, `errorDescription` 37, accessibility labels 32, `TextField/SecureField` 18, NSAlert texts + buttons 31, `Toggle` 14, `Picker` 14, `NSMenuItem(title:)` 12, `.alert`/dialogs 7, notifications 6 | **~930** |
| Distinct capitalised multi-word string literals outside log lines (includes model-facing tool descriptions and prompts, which are not translated) | ~1,690 (~15,800 words) |

**Working estimate: 1,000–1,300 distinct user-visible strings, 10,000–13,000 English words.**
The gap between the two numbers is model-facing text (`ChatTools.swift` tool descriptions, prompt
templates) that stays English, plus strings built in model enums.

Where they sit (call-site count of the first measure):

| Area | Share | Biggest files |
| --- | --- | --- |
| Settings | ~550 (60 %) | `SpeechToTextSettingsTab`, `CustomOpenAIChatEndpointSection`, `MeetingsInAIAppsSection`, `ChatGPTPlanConnectionSection`, `ImprovementSettingsTab`, `ReadAloudSettingsTab`, `WritingStyleSettingsSection`, `MeetingsSettingsTab` |
| Menu bar, pill, popups, alerts | ~155 | `MenuBarController`, `FullApp`, `RecordingIndicatorWindow`, `LiveMeetingSession`, `AutoPromptImprovementScheduler` |
| Chat UI | ~95 (+ ~70 tool-step labels in `ChatToolSteps.swift`) | `ChatView`, `ChatSidebar`, `ChatToolStepsView` |
| Onboarding | ~65 | `Onboarding/WelcomeSteps.swift` |
| MCP proposal windows, Mail card, telemetry sheet | ~50 | `MCP/MCPProposalWindows.swift`, `Mail/MailCredentialCard.swift` |
| Model descriptions, cost levels, enum display names | ~140 | `SettingsConfiguration.swift`, `TranscriptionModels.swift` |

---

## 2. Approach

### 2.1 Mechanism

- **One String Catalog**, `WhisperShortcut/Localizable.xcstrings`, source language `en`, one added
  language `de`. Add `de` to `knownRegions`. No per-feature tables: one file is what the coverage
  check reads, and the app is not large enough to need tables.
- **SwiftUI literals localize for free.** `Text("Save")`, `Button("Cancel")`, `Toggle("…")`,
  `.help("…")` take a `LocalizedStringKey` and are extracted on build. These ~600 sites need no
  code change, only catalog entries.
- **Everything outside a SwiftUI literal uses `String(localized:)`** (or
  `LocalizedStringResource` where the value is passed on): AppKit (`NSMenuItem`, `NSAlert`,
  `NSWindow.title`), `UNNotificationContent`, `LocalizedError.errorDescription`, enum
  `displayName` / `description`, view-model strings, pill labels. Add a `comment:` wherever the
  English is ambiguous out of context ("Stop" the recording vs. "Stop" the playback).
- **The trap: `Text(someString)` does not localize.** A `String` variable goes through
  `Text(verbatim:)` semantics. Every reusable component that takes a title as `String`
  (`SectionHeader`, `SettingsSlot`, `ModelTile`, the cards: ~31 `title: String` parameters, ~38
  `Text(title|label|message|subtitle|text|description)` sites) must take `LocalizedStringKey` or
  `LocalizedStringResource` instead, or its callers pass `String(localized:)`. Prefer changing the
  component: one edit fixes every caller.
- **Interpolation and plurals:** `Text("\(count) meetings")` becomes a catalog entry with a plural
  variation (`%lld meetings` → `ein Meeting` / `%lld Meetings`). Never build sentences by string
  concatenation; German word order differs.
- **Language follows the system.** Nothing to build. The General tab gets one line under About or
  General: "Language: follows macOS. Change it per app in System Settings → Language & Region." with
  a button that opens that pane (`x-apple.systempreferences:com.apple.Localization-Settings.extension`).
- **Formatting:** user-visible dates, durations, numbers and byte sizes go through `.formatted()` /
  `Duration.formatted()` / `ByteCountFormatter` with the current locale. The 31 hard-coded
  `en_US` / `en_US_POSIX` / `dateFormat` sites are reviewed one by one: file names, log timestamps
  and API payloads keep POSIX, anything a user reads moves to the locale.

### 2.2 What is not translated

| Stays English | Why |
| --- | --- |
| Model and provider names (Gemini 3.8 Flash, Parakeet Ultra, GPT-Transcribe, OpenRouter, Ollama) | Proper names. The catalog never sees them: build such labels as `"\(model.displayName)"` with a `Text(verbatim:)` or keep them out of the localized format string. |
| Everything a model reads: system prompts, `system-prompts.md` defaults, tool names and tool descriptions in `ChatTools.swift`, MCP tool descriptions, the Smart Improvement meta-prompts | Prompts are tuned and benchmarked in English; the model answers in the user's language anyway. Translating them would fork every prompt. |
| Log lines (`DebugLogger`), interaction logs, outcome signals, telemetry payloads, hang reports | The loops grep these by literal text (`plans/agent-loops.md`). See 2.3. |
| Slash commands (`/folder`, `/openrouter`, `/feedback`) and model commands | They are typed identifiers. Their *descriptions* in the command popup are translated. |
| File and folder names on disk (`UserContext/`, `system-prompts.md`, meeting file names) | Stable paths; existing installs and docs refer to them. |
| GitHub issue templates, problem-report scaffolding sent to GitHub | The issue tracker is English. The user's own text is kept as written. |
| Keyboard symbols and shortcut glyphs | Not text. |

### 2.3 Logs must not turn German

117 log calls interpolate `error.localizedDescription`. Once `errorDescription` is localized, those
lines are written in German on a German system, and every loop that greps `errors-*.log` for an
English phrase silently stops counting (usage review, implementer falsifiers, `analyze-user-interactions`).

Rule: **logs never use `localizedDescription`.** Add `Error.logDescription` (in `AppErrors.swift`)
that returns `String(describing: error)` for the app's own error enums and the English
`errorDescription` resolved with `String(localized: …, locale: Locale(identifier: "en"))` where an
English sentence is wanted, and route all 117 sites through it. A unit test asserts
`logDescription` is identical under `de` and `en`. The same applies to `ContextLogger` signal
`detail` fields and telemetry: they carry enum raw values, never display strings.

### 2.4 Tests and the coverage check

- **The test plans pin English.** Set `language = en` / `region = US` in
  `WhisperShortcut-Hermetic.xctestplan` and `WhisperShortcut-AppStore.xctestplan`, so tests that
  assert English labels (`PillLabelTests`, `ChatErrorFormatterTests`, …) do not change meaning on a
  German Mac.
- **`LocalizationCoverageTests`** (new, `WhisperShortcutTests/`): loads the bundled
  `Localizable.xcstrings` (JSON) and fails, listing the keys, when
  1. a key has no `de` entry, or its state is not `translated` (`new`, `needs_review`), or
  2. a `de` value drops or reorders a format specifier relative to the English one (`%@`, `%lld`,
     positional `%1$@`), or
  3. a key is `stale` (Xcode marks keys whose source vanished) — stale entries are deleted, not
     kept.
  Until slice A4 the test runs in report mode (prints the missing count, passes); A4 flips it to
  failing. That gives every slice a number to drive to zero.
- **Extraction is part of the build.** The catalog only learns new keys when a build syncs it.
  Slice A0 verifies that `scripts/rebuild-and-restart.sh` (xcodebuild) adds new keys to the
  catalog; if it does not, A0 adds a sync step (`xcodebuild -exportLocalizations` into a temp dir,
  merged back) to `scripts/run-tests.sh`, so a key that never got extracted cannot pass as
  "nothing missing".
- **What the test cannot see:** a `Text(variable)` that never became a catalog key. That is caught
  by (a) the component rule in 2.1, (b) a pseudo-localization pass: launch with
  `-AppleLanguages "(de)"` and walk every screen; any English left is a missed string. The
  `run-whisper-shortcut` skill gets a `--lang de` note for exactly this.

### 2.5 Layout

German runs ~30 % longer than English. Known pressure points:

- `SettingsConstants.labelWidth = 160` (fixed label column across Settings).
- The pill and its Dictate Prompt card (`RecordingIndicatorWindow`), the popup notifications, the
  chat composer toolbar, model tiles in `ModelGrid`, onboarding step buttons.
- Menu bar menu items with shortcut glyphs.

Fix by letting text wrap or by widening, never by abbreviating German words. The Opus session
checks every screen in German and English with screenshots (`run-whisper-shortcut`) before a slice
is done.

### 2.6 The README that the in-app Chat reads

`README.md` `## Features` (~3,000 words) is bundled and served to Chat through
`read_whisper_shortcut_doc`. **It stays English, one file.** A second German README would drift
within a release, and the chat model reads English and answers in German without help.

What breaks is navigation: the README says "Settings → Privacy & Permissions", the German user sees
"Einstellungen → Datenschutz & Berechtigungen". Fix it the same way live shortcut bindings are
already handled (`list_whisper_shortcut_docs` injects them from `ShortcutConfig` at runtime):

- A small `UILabelGlossary` lists the navigation labels the README uses (window titles, Settings
  tab and section names, menu bar items, the main buttons), each as a `LocalizedStringResource`.
- When the app runs in a non-English language, `read_whisper_shortcut_doc` appends a table
  "English label in this document → label on the user's screen", resolved from the catalog, plus
  one instruction: answer in the user's language and name UI elements by their on-screen label.
- A test asserts every label in `UILabelGlossary` appears verbatim in `README.md` (so a renamed
  English label fails the build instead of silently dropping out of the map).

The AGENTS.md rule "when you add or rename a user-facing feature, update README" stays as it is;
the German side follows from the catalog.

---

## 3. Glossary

Decided defaults; the Opus translation pass keeps them consistent and Magnus can overrule any line
in review. Principle: **ordinary verbs and nouns become German; branded feature names that appear
on shortcuts, in the README and in pilot material stay as product names.** macOS German terms win
where Apple has one.

| English | German | Note |
| --- | --- | --- |
| Dictate | **Diktieren** (action), **Diktat** (feature, result) | Plain German; the App Store listing already says "Diktieren". |
| Dictate Prompt | **Dictate Prompt** (product name) | Pilot material and README use it; a German coinage ("Sprachbearbeitung") hides that it also writes new text. Where the feature is first introduced (onboarding, its Settings tab header) add a German subtitle: "Text per Sprache bearbeiten oder schreiben". |
| Read Aloud | **Vorlesen** | Ordinary verb; App Store listing uses it. |
| Live Meeting / Meeting | **Live-Meeting** / **Meeting** | "Meeting" is common German office usage; "Besprechung" reads stiff. |
| Chat | **Chat** | |
| Glossary | **Glossar** | Pilot material uses it. |
| Offline Mode | **Offline-Modus** | Pilot material uses it (17×). |
| Smart Improvement | **Smart Improvement** (product name) | Settings tab name stays; descriptions are German. |
| Writing Style | **Schreibstil** | |
| Welcome Tour | **Einführung** | Menu item "Einführung…" |
| Settings | **Einstellungen** | macOS term. |
| Accounts | **Konten** | |
| Privacy & Permissions | **Datenschutz & Berechtigungen** | |
| Clipboard | **Zwischenablage** | macOS term. |
| Auto-paste | **Automatisch einfügen** | |
| Restore clipboard | **Zwischenablage wiederherstellen** | |
| Screenshot | **Bildschirmfoto** | macOS term. |
| Commands (user commands) | **Befehle** | |
| Custom endpoint | **Eigener Endpunkt** | |
| API key | **API-Schlüssel** | |
| Shortcut | **Tastenkürzel** | macOS term. |
| Usage report | **Nutzungsbericht** | |
| Send Feedback | **Feedback senden** | |
| Problem report | **Problembericht** | |
| Popup | **Hinweis** | |

**Form of address: `Sie`** (decided by Magnus, 2026-10-26). App, website and, from the next
version, the de-DE App Store listing, which still uses `du` today and can only change with a
version submission. The pilot audience is medical practices, and the German `/praxis` page already
uses `Sie`.

---

## 4. Translation workflow

1. **Opus drafts.** UI copy is Opus's work under the model split, not the cheap hands'. The Opus
   session fills the `de` column per area, with the glossary and the `comment:` context, and writes
   for the screen (short, imperative, macOS register), not a sentence-by-sentence rendering.
2. **Layout check in the running app**, German and English, screenshots of every screen touched
   (2.5).
3. **Magnus reviews** in the app, not in the catalog: a German build plus a screenshot sheet per
   slice. Corrections go into the catalog and, if they change a glossary decision, into section 3.
4. **State discipline:** entries Opus writes are `translated`; anything Opus is unsure about stays
   `needs_review` with a comment, which keeps the coverage test red until Magnus has decided.

**Afterwards, for every new string:** the author of a change that adds or edits a user-facing
English string adds the German in the same change. The coverage test (A4 onwards) fails otherwise.
Plumbing hands that add UI strings by accident leave them `needs_review`; the reviewing Opus pass
fills them.

---

## 5. Slices and queue rows

Order: A0 first (everything else depends on the catalog and the component signatures), then A1–A3
in any order, A4 last. The website half can run in parallel from day one; its German pages may say
"die App ist auf Deutsch" only after A4 ships.

| Slice | Who | Content | Size |
| --- | --- | --- | --- |
| **A0 Plumbing** | Grok / Sonnet, interactive (touches `project.pbxproj` and test plans, outside `IMPLEMENTER_SCOPE`) | Catalog with `de`, `knownRegions`, test plans pinned to `en`, `Error.logDescription` and the 117 log sites, component signatures to `LocalizedStringKey`/`LocalizedStringResource`, AppKit/enum/error strings to `String(localized:)`, cost-level strings to an enum, `LocalizationCoverageTests` in report mode, extraction verified | 1–2 sessions |
| **A1 German: everyday surfaces** | Opus | Menu bar menu, pill and Dictate Prompt card, popups and alerts, onboarding, errors | ~350 strings |
| **A2 German: Settings** | Opus | All Settings tabs and components, model descriptions | ~550 strings, two sittings |
| **A3 German: Chat and the rest** | Opus (UI) + Sonnet (`UILabelGlossary` plumbing) | Chat window, sidebar, tool steps, command popup descriptions, meetings, MCP proposal windows, mail card, telemetry sheet; README label map (2.6); the "Language follows macOS" line | ~300 strings |
| **A4 Gate** | Sonnet | Flip coverage test to failing, update `.cursor/rules/user-facing-text-english.mdc` in the workspace repo and the submodule rule index, add German to the `run-whisper-shortcut` skill and to release notes | small |

Rough total: two plumbing sessions, four Opus copy sessions, and about three to four hours of
Magnus reading German screens.

The rows below are filed in `plans/implementer-queue.md` as rows **49–53** (A0–A4), `ASK` / `OPEN`: they are built
interactively (A0 needs the project file, the others are Opus UI work), and the runner must not
pick them.

- **A0** — Localization plumbing: `Localizable.xcstrings` (en source, de), `de` in `knownRegions`,
  test plans pinned to `en`, `Error.logDescription` replacing `localizedDescription` in all log
  calls, `String`-title components switched to `LocalizedStringKey`/`LocalizedStringResource`,
  AppKit/notification/error/enum strings through `String(localized:)`, `LocalizationCoverageTests`
  in report mode. No German copy in this row. *Falsifier:* after `bash scripts/run-tests.sh`, the
  catalog holds ≥ 900 keys and the coverage test prints the missing-`de` count; launched with
  `-AppleLanguages "(en)"` every screen is unchanged; `grep -rn 'localizedDescription' WhisperShortcut | grep -i log`
  returns nothing; `logDescription` test passes under `de`.
- **A1** — German copy for menu bar, pill, Dictate Prompt card, popups, alerts, onboarding, error
  texts. *Falsifier:* launched with `-AppleLanguages "(de)"`, a walkthrough (first launch → onboarding
  → dictate → Dictate Prompt → an error popup) shows no English outside model names; English launch
  unchanged; coverage count for these files is 0.
- **A2** — German copy for all Settings tabs and model descriptions; `labelWidth` and tiles fit
  German without truncation. *Falsifier:* screenshots of every Settings tab in German show no
  truncated label (`…`) and no English outside proper names; coverage count for `Settings/` is 0.
- **A3** — German copy for Chat, meetings, MCP windows, mail card, telemetry sheet; `UILabelGlossary`
  and the label map in `read_whisper_shortcut_doc`. *Falsifier:* in a German build, asking Chat
  "Wo schalte ich den Offline-Modus ein?" gets an answer naming "Einstellungen → Datenschutz &
  Berechtigungen"; the glossary test passes.
- **A4** — Coverage test fails on any missing or `needs_review` `de` entry; rule files updated.
  *Falsifier:* adding `Text("Probe")` without a German entry makes `bash scripts/run-tests.sh` fail
  with that key named.

---

## 6. Decisions taken

- **`Sie`, not `du`** (Magnus, 2026-10-26): "Use Sie in the app, on the website and, from the next
  version, in the App Store listing."

## 7. Out of scope (follow-ups)

- German App Store screenshots (they should show the German UI once A1–A3 ship) and aligning the
  de-DE listing with the glossary.
- Other languages. The mechanism carries them; the coverage test would take a language list.
- Localized default system prompts. The models already answer in the dictation's language.
