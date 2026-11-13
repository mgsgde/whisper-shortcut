# Dictation only mode

Status: active. Built in slices (see "Slices").

## Why

Many new users want one thing: press a key, speak, text appears at the cursor, offline, with
spoken punctuation, live text and a glossary. The full app shows chat, meetings, MCP, API keys,
model pickers and a dozen settings tabs, which makes a first setup long and error-prone for
non-technical users. "Dictation only" is a mode of the same app that shows only dictation and a
first run that ends in a working offline dictation in about ten minutes without help.

## Decisions

1. **Name in UI:** "Dictation only" (German "Nur Diktat"). Neutral wording, no field of use named.
2. **Single source of truth:** one UserDefaults bool, `dictationOnlyMode`, default false. Existing
   installs do not change. Turning it off brings the full app back; no data, binding or setting
   is deleted by the mode.
3. **Entry:** first onboarding screen offers two cards, "Dictation only" and "All features".
   A switch in Settings → General changes it later.
4. **Defaults are applied once, only by the onboarding card**, never at launch and never by the
   Settings switch (the switch only hides and shows). Applied in this order, guarded by a
   `dictationOnlyDefaultsApplied` marker:
   Offline Mode on → Parakeet model selected → dictation language = Mac language if supported,
   else an explicit pick (never auto-detect) → Dictate Live on (direct build on Apple Silicon
   only, otherwise plain Dictate) → spoken punctuation on.
   Offline Mode stays on if the mode is later switched off; the copy says so.
5. **Hidden while on:** Chat, Meetings, AI apps/MCP, Accounts/API keys, model and provider
   pickers, Read Aloud, Screenshot, Dictate Prompt, Templates. Hidden means: not in the status
   menu, not in Settings, global shortcuts not registered (bindings are kept), MCP server not
   started, chat not pre-warmed. Entry functions (`openChatWindow`, `toggleLiveMeeting`,
   `togglePrompting`, `takeScreenshot`, read aloud) carry a guard as backstop because Services
   and popups can still reach them. Settings then shows General, Dictation (language, dictate
   mode, punctuation, glossary), Permissions, About.
6. **Switching while busy:** the switch is refused while a meeting or recording runs. The switch
   never stops anything.
7. **Build targets:** works in both. The App Store build has no auto-paste, no Dictate Live, no
   Fn dictation and cannot read the globe key setting; there the copy promises "paste with ⌘V"
   and the globe step and the Accessibility step are skipped.
8. **Onboarding in this mode** (own step list with new raw values, resume by list membership):
   mode choice → globe key (direct build) → language confirmation → microphone and Accessibility
   with one sentence that the Touch ID/password prompt comes from macOS → model download (other
   steps may proceed meanwhile, only the test waits; check free disk space) → test dictation
   inside the window (about 8 s) → one glossary word, then repeat the test.
   The /Applications check already runs at launch (`ApplicationsFolderMove`).
9. **Tests take the flag as a parameter** (pure functions `visibleTabs(enabled:)`,
   `menuRows(enabled:)`, `registersShortcut(_:enabled:)`), as `OfflineMode` does.

## Slices

1. Flag, gating of menu, settings tabs, shortcuts, MCP start, chat pre-warm, launch fallback;
   default application (`DictationOnlyDefaults`). No visible switch yet.
2. Settings switch, trimmed Dictation tab, strings (English + German), README feature entry.
3. Onboarding flow.

## Out of scope

Specialty glossary packs, a separate product or bundle ID, payment.
